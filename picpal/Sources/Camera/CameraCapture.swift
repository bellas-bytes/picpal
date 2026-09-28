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
    let sessionQueue = DispatchQueue(label: QueueLabels.session, qos: .userInitiated)
    /// Frame sample-buffer delivery queue, separate from the session queue.
    private let frameQueue   = DispatchQueue(label: QueueLabels.frames,  qos: .userInitiated)

    // MARK: - Lock-protected state

    // OSAllocatedUnfairLock stores value types; one lock per guarded value keeps
    // lock granularity fine-grained and avoids priority-inversion risks.

    private let stateLock = OSAllocatedUnfairLock<CaptureState>(initialState: .idle)
    private let configLock: OSAllocatedUnfairLock<CameraConfiguration>
    private let orientationTransition = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let orientationLock = OSAllocatedUnfairLock<CaptureOrientation>(initialState: .portrait)
    private let positionLock = OSAllocatedUnfairLock<AVCaptureDevice.Position>(initialState: .back)
    // Set synchronously before enqueueing stop work; checked by startSession before
    // calling captureSession.startRunning(), so stop() during .starting aborts cleanly.
    private let cancellationRequested = OSAllocatedUnfairLock<Bool>(initialState: false)

    // Delegate is a weak reference inside a class wrapper so the lock can store it.
    private let delegateBox = DelegateBox()

    private let logger = Logger(subsystem: "com.picpal", category: "CameraCapture")

    // MARK: - AVFoundation objects  (mutated only on sessionQueue)

    nonisolated(unsafe) public private(set) var captureSession = AVCaptureSession()
    nonisolated(unsafe) var photoOutput = AVCapturePhotoOutput()
    var pendingPhoto: PhotoCaptureDelegate?
    nonisolated(unsafe) private var videoOutput    = AVCaptureVideoDataOutput()
    /// Retained to keep the delegate alive for the lifetime of the output.
    nonisolated(unsafe) private var sampleReceiver: SampleBufferReceiver?
    /// The active capture device. Set on `sessionQueue`; read on any thread (nonisolated).
    nonisolated(unsafe) public private(set) var videoDevice: AVCaptureDevice?

    // MARK: - Exposure-bias state (written from the UI on the main thread)

    /// `true` when the user has manually set a non-zero EV bias via `setExposureBias(_:)`.
    /// Resets to `false` when bias returns to 0. Used by `CueEngine` to suppress
    /// exposure coaching cues while the user is in manual EV control.
    ///
    /// `internal(set)` so `CameraCapture+ExposureControl.swift` can write it from the
    /// same module without `private(set)` restricting it to one file.
    private let manualBiasLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    public internal(set) var exposureBiasIsManual: Bool {
        get { manualBiasLock.withLock { $0 } }
        set { manualBiasLock.withLock { $0 = newValue } }
    }

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

    public var orientation: CaptureOrientation { orientationLock.withLock { $0 } }

    public func setOrientation(_ orientation: CaptureOrientation) {
        orientationTransition.withLock { $0 += 1 }
        orientationLock.withLock { $0 = orientation }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            configureVideoConnection()
            // Drain already queued old-orientation buffers before accepting new evidence.
            frameQueue.async { [weak self] in
                self?.orientationTransition.withLock { $0 -= 1 }
            }
        }
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

    /// Toggle cameras and return the actual position after configuration commits.
    /// Failed or unavailable switches preserve the current position.
    public func switchCamera() async -> AVCaptureDevice.Position {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                guard stateLock.withLock({ $0 }) == .running, pendingPhoto == nil else {
                    continuation.resume(returning: cameraPosition)
                    return
                }
                let newPosition: AVCaptureDevice.Position = cameraPosition == .back ? .front : .back
                guard let device = Self.preferredDevice(position: newPosition),
                      let input = try? AVCaptureDeviceInput(device: device) else {
                    continuation.resume(returning: cameraPosition)
                    return
                }
                // Keep old-camera frames out of the analysis pipeline until queued
                // buffers have drained after the input and geometry change.
                orientationTransition.withLock { $0 += 1 }
                captureSession.beginConfiguration()
                let oldInputs = captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                for old in oldInputs { captureSession.removeInput(old) }
                if captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                    videoDevice = device
                    configurePhotoDimensions()
                    do { try applyFrameRate(configLock.withLock { $0 }.targetFPS, to: device) }
                    catch { logger.error("switchCamera frame rate: \(error.localizedDescription)") }
                    enableAutomaticAdjustments()
                } else {
                    for old in oldInputs where captureSession.canAddInput(old) { captureSession.addInput(old) }
                }
                configureVideoConnection(notify: false)
                captureSession.commitConfiguration()
                positionLock.withLock { $0 = videoDevice?.position ?? .back }
                configureVideoConnection()
                let committedPosition = cameraPosition
                frameQueue.async { [self] in
                    orientationTransition.withLock { $0 -= 1 }
                    continuation.resume(returning: committedPosition)
                }
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

            configurePhotoDimensions()
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
        defer {
            captureSession.commitConfiguration()
            configureVideoConnection()
        }

        // Clear any existing inputs and outputs before rebuilding.
        for input in captureSession.inputs { captureSession.removeInput(input) }
        for output in captureSession.outputs { captureSession.removeOutput(output) }

        captureSession.sessionPreset = captureSession.canSetSessionPreset(.photo) ? .photo : configuration.preset

        let position = positionLock.withLock { $0 }
        guard let device = Self.preferredDevice(position: position) else {
            throw CameraError.deviceUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard captureSession.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        captureSession.addInput(input)
        videoDevice = device

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
        photoOutput = AVCapturePhotoOutput()
        guard captureSession.canAddOutput(photoOutput) else { throw CameraError.cannotAddOutput }
        captureSession.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        configurePhotoDimensions()
        enableAutomaticAdjustments()
    }

    /// Reconfigure a running session without rebuilding it. Must be called on `sessionQueue`.
    private func applyConfigurationLocked(_ configuration: CameraConfiguration) {
        guard pendingPhoto == nil else { return }
        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
            configureVideoConnection()
            configurePhotoDimensions()
        }

        captureSession.sessionPreset = captureSession.canSetSessionPreset(.photo) ? .photo : configuration.preset

        guard let device = (captureSession.inputs.first as? AVCaptureDeviceInput)?.device else {
            return
        }
        do {
            try applyFrameRate(configuration.targetFPS, to: device)
        } catch {
            logger.error("applyFrameRate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    static let connectionsChangedNotification = Notification.Name("com.picpal.cameraConnectionsChanged")

    private static func preferredDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // Center Stage front cameras expose their full field of view through ultra-wide.
        if position == .front,
           let wide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .front) {
            return wide
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Physically rotates analysis buffers upright so Vision's `.up` orientation is valid.
    /// Front-camera buffers match the mirrored preview and saved photo coordinates.
    /// Must run on the session queue after connections have been established.
    private func configureVideoConnection(notify: Bool = true) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported { connection.videoOrientation = orientation.videoOrientation }
        #if DEBUG
        print("[PicPal orientation] camera=\(videoDevice?.position.rawValue ?? 0) portraitRotation=\(connection.videoRotationAngle)")
        #endif
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = videoDevice?.position == .front
        }
        if notify {
            NotificationCenter.default.post(name: Self.connectionsChangedNotification, object: captureSession)
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
        guard orientationTransition.withLock({ $0 == 0 }) else { return }
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
