import AVFoundation
import CoreMedia
import CoreVideo
import MediaPipeTasksVision
import os

// MARK: - Sendable bridge

/// Wraps `CVPixelBuffer` (non-Sendable Core Foundation type) so it can safely
/// cross isolation contexts into the serial `probeQueue`. The serial queue
/// guarantees the buffer is not accessed concurrently.
private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

// MARK: - Probe constants

private enum MediaPipeProbeConstants {
    static let queueLabel                  = "com.picpal.landmarks.mediapipe"
    static let minHandDetectionConfidence: Float = 0.5
    static let minHandPresenceConfidence: Float  = 0.5
    static let handTrackingConfidence: Float     = 0.5
    static let maxHands: Int                     = 1
    static let minFaceDetectionConfidence: Float = 0.5
    static let minFacePresenceConfidence: Float  = 0.5
    static let faceTrackingConfidence: Float     = 0.5
    static let maxFaces: Int                     = 1
    /// Minimum monotonic increment (ms) to guarantee strictly-increasing timestamps.
    static let minTimestampStepMs: Int           = 1
}

// MARK: - Error

/// Errors thrown during `MediaPipeLandmarkProbe` initialisation.
public enum MediaPipeLandmarkProbeError: Error, Sendable {
    /// A required `.task` model bundle was not found in `Bundle.main`.
    case modelNotFound(String)
}

// MARK: - Probe

/// Runs MediaPipe `HandLandmarker` and `FaceLandmarker` against each camera
/// frame and reports per-model latency via `onProbeStats`.
///
/// ## Purpose
/// This is the **M2-0 measurement harness**. It compares MediaPipe hand + face
/// latency against the Vision baseline (Hand 84.1 ms, Face 24.3 ms, combined
/// 140.7 ms p95) to inform the PROCEED / FALLBACK A / FALLBACK B decision.
///
/// ## Running mode
/// Both landmarkers use `.video` mode with strictly-increasing millisecond
/// timestamps derived from the camera's `CMTime`, as required by MediaPipe's
/// streaming API.
///
/// ## Threading
/// Frame callbacks arrive on the camera's dedicated queue. All MediaPipe work
/// is dispatched to a serial `probeQueue` so the camera queue is never blocked.
///
/// ## Swift 6 concurrency
/// `MediaPipeLandmarkProbe` is `@unchecked Sendable`. All mutable state is
/// protected by `OSAllocatedUnfairLock`. `CameraFrameDelegate` methods are
/// `nonisolated`, matching the framework contract.
public final class MediaPipeLandmarkProbe: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Serial work queue

    private let probeQueue = DispatchQueue(
        label: MediaPipeProbeConstants.queueLabel,
        qos: .userInitiated
    )

    // MARK: - MediaPipe landmarkers

    /// Non-Sendable ObjC objects — accessed exclusively from `probeQueue`.
    private let handLandmarker: HandLandmarker
    private let faceLandmarker: FaceLandmarker

    // MARK: - Per-model timers (actors)

    private let handTimer     = FrameTimer()
    private let faceTimer     = FrameTimer()
    private let combinedTimer = FrameTimer()

    // MARK: - Protected state

    private let enabledLock:    OSAllocatedUnfairLock<Bool>
    private let frameCountLock: OSAllocatedUnfairLock<Int>
    /// Last emitted timestamp in ms — enforces strict monotonicity.
    private let lastTimestampLock: OSAllocatedUnfairLock<Int>

    // MARK: - Callback + logger

    private let onProbeStats: @Sendable (MediaPipeProbeStats) -> Void
    private let logger = Logger(subsystem: "com.picpal", category: "MediaPipeLandmarkProbe")

    // MARK: - Downstream chaining

    // Written once at init; never mutated afterward. ARC guarantees atomic
    // zeroing on deallocation, so nonisolated reads are safe without a lock.
    private weak var downstream: (any CameraFrameDelegate)?

    // MARK: - Init

    /// Creates a `MediaPipeLandmarkProbe`.
    ///
    /// Loads `hand_landmarker.task` and `face_landmarker.task` from
    /// `Bundle.main`. Both model files must be present in the app bundle
    /// (added via `PicPal/Resources/Models/` in `project.yml`).
    ///
    /// - Parameters:
    ///   - isEnabled: When `false` the probe ignores incoming frames.
    ///   - downstream: Next pipeline delegate; receives every frame regardless
    ///     of the `isEnabled` state.
    ///   - onProbeStats: Invoked (off-main) after each processed frame.
    /// - Throws: `MediaPipeLandmarkProbeError.modelNotFound` if either model
    ///   bundle is missing from `Bundle.main`.
    public init(
        isEnabled: Bool = true,
        downstream: (any CameraFrameDelegate)? = nil,
        onProbeStats: @escaping @Sendable (MediaPipeProbeStats) -> Void
    ) throws {
        enabledLock      = OSAllocatedUnfairLock(initialState: isEnabled)
        frameCountLock   = OSAllocatedUnfairLock(initialState: 0)
        lastTimestampLock = OSAllocatedUnfairLock(initialState: 0)
        self.downstream  = downstream
        self.onProbeStats = onProbeStats

        // --- Hand Landmarker ---
        guard let handModelPath = Bundle.main.path(
            forResource: "hand_landmarker", ofType: "task"
        ) else {
            throw MediaPipeLandmarkProbeError.modelNotFound("hand_landmarker.task")
        }
        let handOptions = HandLandmarkerOptions()
        handOptions.baseOptions.modelAssetPath = handModelPath
        handOptions.runningMode                = .video
        handOptions.minHandDetectionConfidence = MediaPipeProbeConstants.minHandDetectionConfidence
        handOptions.minHandPresenceConfidence  = MediaPipeProbeConstants.minHandPresenceConfidence
        handOptions.minTrackingConfidence      = MediaPipeProbeConstants.handTrackingConfidence
        handOptions.numHands                   = MediaPipeProbeConstants.maxHands
        self.handLandmarker = try HandLandmarker(options: handOptions)

        // --- Face Landmarker ---
        guard let faceModelPath = Bundle.main.path(
            forResource: "face_landmarker", ofType: "task"
        ) else {
            throw MediaPipeLandmarkProbeError.modelNotFound("face_landmarker.task")
        }
        let faceOptions = FaceLandmarkerOptions()
        faceOptions.baseOptions.modelAssetPath = faceModelPath
        faceOptions.runningMode                = .video
        faceOptions.minFaceDetectionConfidence = MediaPipeProbeConstants.minFaceDetectionConfidence
        faceOptions.minFacePresenceConfidence  = MediaPipeProbeConstants.minFacePresenceConfidence
        faceOptions.minTrackingConfidence      = MediaPipeProbeConstants.faceTrackingConfidence
        faceOptions.numFaces                   = MediaPipeProbeConstants.maxFaces
        self.faceLandmarker = try FaceLandmarker(options: faceOptions)
    }

    // MARK: - Public API

    /// Toggle MediaPipe processing on/off. Thread-safe; may be set from any context.
    public var isEnabled: Bool {
        get { enabledLock.withLock { $0 } }
        set { enabledLock.withLock { $0 = newValue } }
    }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        guard enabledLock.withLock({ $0 }) else { return }

        // Derive a strictly-increasing millisecond timestamp for MediaPipe .video mode.
        let timestampMs = lastTimestampLock.withLock { last -> Int in
            let ms = Int(CMTimeGetSeconds(timestamp) * 1_000)
            let next = max(ms, last + MediaPipeProbeConstants.minTimestampStepMs)
            last = next
            return next
        }

        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        probeQueue.async { [weak self] in
            self?.runProbe(pixelBuffer: wrapped.value, timestampMs: timestampMs)
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }

    // MARK: - Private: MediaPipe execution

    private func runProbe(pixelBuffer: CVPixelBuffer, timestampMs: Int) {
        guard let mpImage = try? MPImage(pixelBuffer: pixelBuffer) else {
            logger.debug("MediaPipeLandmarkProbe: failed to create MPImage")
            return
        }

        let combinedToken = combinedTimer.start()

        // --- Hand Landmarker ---
        let handToken = handTimer.start()
        do {
            _ = try handLandmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestampMs)
        } catch {
            logger.error("Hand detect failed: \(error.localizedDescription, privacy: .public)")
        }
        let handEnd = ContinuousClock.now

        // --- Face Landmarker ---
        let faceToken = faceTimer.start()
        do {
            _ = try faceLandmarker.detect(videoFrame: mpImage, timestampInMilliseconds: timestampMs)
        } catch {
            logger.error("Face detect failed: \(error.localizedDescription, privacy: .public)")
        }
        let faceEnd = ContinuousClock.now

        let combinedEnd = faceEnd

        let count = frameCountLock.withLock { count -> Int in
            count += 1
            return count
        }

        Task { [weak self] in
            guard let self else { return }
            await handTimer.stop(token: handToken,     endInstant: handEnd)
            await faceTimer.stop(token: faceToken,     endInstant: faceEnd)
            await combinedTimer.stop(token: combinedToken, endInstant: combinedEnd)

            async let handStats     = handTimer.statistics
            async let faceStats     = faceTimer.statistics
            async let combinedStats = combinedTimer.statistics

            let (h, f, c) = await (handStats, faceStats, combinedStats)

            onProbeStats(MediaPipeProbeStats(
                handPoseMs: h.meanMs,
                faceMeshMs: f.meanMs,
                combinedMs: c.meanMs,
                frameCount: count
            ))
        }
    }
}
