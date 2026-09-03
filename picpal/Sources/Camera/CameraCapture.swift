import AVFoundation
import CoreMedia
import CoreVideo
import os

/// Manages an `AVCaptureSession` that streams `CVPixelBuffer` frames via `CameraFrameDelegate`.
///
/// ## Usage
/// ```swift
/// let camera = CameraCapture()
/// camera.delegate = self
/// camera.configure(preset: .hd1280x720, fps: 30)
/// camera.requestPermissionAndStart()
/// ```
///
/// ## Thread-safety model
/// - All AVFoundation session operations are serialised on the internal `sessionQueue`.
/// - `captureState` reads are lock-protected and safe from any thread.
/// - `delegate` is lock-protected; safe to assign from any thread before or after start.
/// - Frame callbacks arrive on the dedicated `frameQueue` (never the main or session queue).
/// - State-change callbacks are dispatched to the **main queue**.
///
/// `CameraCapture` is `@unchecked Sendable`: the class crosses isolation contexts safely
/// because all mutable state is synchronised via `OSAllocatedUnfairLock` or serial queues.
///
/// `CaptureState` is defined in `CaptureState.swift`; `DelegateBox` and `SampleBufferReceiver`
/// are defined in `CameraCapture+Internal.swift`.
public final class CameraCapture: @unchecked Sendable {

    // MARK: - Internal constants

    private enum QueueLabels {
        static let session = "com.picpal.camera.session"
        static let frames  = "com.picpal.camera.frames"
    }

    // MARK: - Queues (immutable — safe to access across isolation contexts)

    /// All AVFoundation session mutations are serialised here.
    private let sessionQueue = DispatchQueue(label: QueueLabels.session, qos: .userInitiated)
    /// Frame sample-buffer delivery queue, separate from the session queue.
    private let frameQueue   = DispatchQueue(label: QueueLabels.frames,  qos: .userInitiated)

    // MARK: - Lock-protected state

    // OSAllocatedUnfairLock stores value types; one lock per guarded value keeps
    // lock granularity fine-grained and avoids priority-inversion risks.

    private let stateLock = OSAllocatedUnfairLock<CaptureState>(initialState: .idle)
    private let configLock: OSAllocatedUnfairLock<CameraConfiguration>
    private let positionLock = OSAllocatedUnfairLock<AVCaptureDevice.Position>(initialState: .back)
    // Set synchronously before enqueueing stop work; checked by startSession before
    // calling captureSession.startRunning(), so stop() during .starting aborts cleanly.
    private let cancellationRequested = OSAllocatedUnfairLock<Bool>(initialState: false)

    // Delegate is a weak reference inside a class wrapper so the lock can store it.
    private let delegateBox = DelegateBox()

    private let logger = Logger(subsystem: "com.picpal", category: "CameraCapture")

    // MARK: - AVFoundation objects  (mutated only on sessionQueue)

    nonisolated(unsafe) public private(set) var captureSession = AVCaptureSession()
    nonisolated(unsafe) private var videoOutput    = AVCaptureVideoDataOutput()
    /// Retained to keep the delegate alive for the lifetime of the output.
    nonisolated(unsafe) private var sampleReceiver: SampleBufferReceiver?

    // MARK: - Public interface

    /// Current capture lifecycle state. Thread-safe; observable from any context.
    public var captureState: CaptureState {
        stateLock.withLock { $0 }
    }

    /// The configuration in effect (or queued for next session start).
    public var currentConfiguration: CameraConfiguration {
        configLock.withLock { $0 }
    }

    /// The camera position currently in use (front or back). Thread-safe.
    public var cameraPosition: AVCaptureDevice.Position {
        positionLock.withLock { $0 }
    }

    /// Receiver of frame and state events. Safe to assign from any thread.
    public weak var delegate: (any CameraFrameDelegate)? {
        get { delegateBox.get() }
        set { delegateBox.set(newValue) }
    }

    // MARK: - Init

    public init() {
        configLock = OSAllocatedUnfairLock(initialState: .defaultConfiguration)
    }

    // MARK: - Configuration

    /// Update the capture resolution and frame rate.
    ///
    /// Safe to call at any time. If the session is already running, the change takes effect
    /// immediately (via `beginConfiguration` / `commitConfiguration`).
    /// `fps` is clamped to `[CameraConfiguration.minimumFPS, CameraConfiguration.maximumFPS]`.
    public func configure(preset: AVCaptureSession.Preset, fps: Int) {
        let newConfig = CameraConfiguration(preset: preset, targetFPS: fps)
        configLock.withLock { $0 = newConfig }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if stateLock.withLock({ $0 }) == .running {
                let latestConfig = configLock.withLock { $0 }
                applyConfigurationLocked(latestConfig)
            }
        }
    }

    // MARK: - Lifecycle

    /// Check and, if needed, request camera permission, then start the capture session.
    ///
    /// If permission is already granted the session starts immediately (on the session queue).
    /// If permission has been denied or restricted, the delegate receives the appropriate state.
    public func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startSession()
                } else {
                    self.setStateAndNotify(.permissionDenied)
                }
            }
        case .denied:
            setStateAndNotify(.permissionDenied)
        case .restricted:
            setStateAndNotify(.permissionRestricted)
        @unknown default:
            setStateAndNotify(.error("Unknown camera authorization status"))
        }
    }

    /// Stop the active capture session and return to `.idle`.
    ///
    /// Safe to call during `.starting` — sets a cancellation flag that `startSession`
    /// checks before calling `captureSession.startRunning()`.
    public func stop() {
        cancellationRequested.withLock { $0 = true }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            defer { cancellationRequested.withLock { $0 = false } }
            switch stateLock.withLock({ $0 }) {
            case .running:
                setStateAndNotify(.stopping)
                captureSession.stopRunning()
                setStateAndNotify(.idle)
            default:
                break  // .starting: startSession's abort path already set state to .idle
            }
        }
    }

    // MARK: - Camera position

    /// Toggle between front and back camera.
    ///
    /// The position flips atomically and is immediately visible via `cameraPosition`.
    /// If the session is running, the capture input is swapped on the session queue
    /// without stopping the session (uses `beginConfiguration` / `commitConfiguration`).
    public func switchCamera() {
        // Flip position synchronously so callers can read it immediately.
        positionLock.withLock { $0 = ($0 == .back) ? .front : .back }
        let newPosition = positionLock.withLock { $0 }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard stateLock.withLock({ $0 }) == .running else { return }
            let config = configLock.withLock { $0 }

            captureSession.beginConfiguration()
            defer { captureSession.commitConfiguration() }

            // Remove the existing device input.
            for input in captureSession.inputs where input is AVCaptureDeviceInput {
                captureSession.removeInput(input)
            }

            guard let device = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: newPosition
            ) else {
                logger.error("switchCamera: no device for position \(String(describing: newPosition), privacy: .public)")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard captureSession.canAddInput(input) else { return }
                captureSession.addInput(input)
                try applyFrameRate(config.targetFPS, to: device)
            } catch {
                logger.error("switchCamera input error: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Private: session setup

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard stateLock.withLock({ $0 }) == .idle else { return }
            setStateAndNotify(.starting)

            let config = configLock.withLock { $0 }
            do {
                try buildSession(configuration: config)
            } catch {
                setStateAndNotify(.error(error.localizedDescription))
                return
            }

            // Abort if stop() was called while the session was being built.
            guard !cancellationRequested.withLock({ $0 }) else {
                setStateAndNotify(.idle)
                return
            }

            captureSession.startRunning()
            setStateAndNotify(.running)
        }
    }

    /// Configure the capture session with the given configuration. Must be called on `sessionQueue`.
    ///
    /// Reuses the existing `captureSession` instance (does not replace it) so that any
    /// `AVCaptureVideoPreviewLayer` already connected to `captureSession` stays wired.
    private func buildSession(configuration: CameraConfiguration) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Clear any existing inputs and outputs before rebuilding.
        for input in captureSession.inputs { captureSession.removeInput(input) }
        for output in captureSession.outputs { captureSession.removeOutput(output) }

        captureSession.sessionPreset = configuration.preset

        let position = positionLock.withLock { $0 }
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: position
        ) else {
            throw CameraError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        captureSession.addInput(input)

        try applyFrameRate(configuration.targetFPS, to: device)

        videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        let receiver = SampleBufferReceiver { [weak self] pixelBuffer, timestamp in
            self?.deliverFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
        sampleReceiver = receiver
        videoOutput.setSampleBufferDelegate(receiver, queue: frameQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        captureSession.addOutput(videoOutput)
    }

    /// Reconfigure a running session without rebuilding it. Must be called on `sessionQueue`.
    private func applyConfigurationLocked(_ configuration: CameraConfiguration) {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = configuration.preset

        guard let device = (captureSession.inputs.first as? AVCaptureDeviceInput)?.device else {
            return
        }
        do {
            try applyFrameRate(configuration.targetFPS, to: device)
        } catch {
            logger.error("applyFrameRate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Set `activeVideoMinFrameDuration` / `Max` on `device` for the requested FPS.
    /// Silently skips if the device's active format doesn't support the rate.
    private func applyFrameRate(_ fps: Int, to device: AVCaptureDevice) throws {
        let targetDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let supported = device.activeFormat.videoSupportedFrameRateRanges
        guard supported.contains(where: { $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate }) else {
            return  // Requested FPS outside the format's supported range — skip silently.
        }
        try device.lockForConfiguration()
        device.activeVideoMinFrameDuration = targetDuration
        device.activeVideoMaxFrameDuration = targetDuration
        device.unlockForConfiguration()
    }

    // MARK: - Private: delivery helpers

    /// Called from `frameQueue` by the `SampleBufferReceiver`.
    private func deliverFrame(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        delegateBox.get()?.cameraCapture(self, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    /// Update state lock and dispatch a state-change notification to the delegate on the main queue.
    private func setStateAndNotify(_ state: CaptureState) {
        stateLock.withLock { $0 = state }
        let captureRef = self
        if let del = delegateBox.get() {
            DispatchQueue.main.async {
                del.cameraCapture(captureRef, didChangeState: state)
            }
        }
    }
}
