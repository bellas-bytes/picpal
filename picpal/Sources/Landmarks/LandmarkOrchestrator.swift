import AVFoundation
import CoreMedia
import CoreVideo
import MediaPipeTasksVision
import os
import Vision

// MARK: - Sendable wrapper

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

// MARK: - Constants

private enum OrchestratorConstants {
    static let queueLabel                        = "com.picpal.landmarks.orchestrator"
    static let minHandDetectionConfidence: Float = 0.5
    static let minHandPresenceConfidence: Float  = 0.5
    static let handTrackingConfidence: Float     = 0.5
    static let maxHands: Int                     = 2   // concat all hands → HandObstructionAnalyzer
    static let minFaceDetectionConfidence: Float = 0.5
    static let minFacePresenceConfidence: Float  = 0.5
    static let faceTrackingConfidence: Float     = 0.5
    static let maxFaces: Int                     = 1
    /// Minimum monotonic increment (ms) for MediaPipe .video mode.
    static let minTimestampStepMs: Int           = 1
}

// MARK: - LandmarkOrchestrator

/// Routes settled camera frames through Vision body pose and MediaPipe hand/face
/// inference, feeds the three M2 signal producers, and emits a merged `BodySignal`.
///
/// ## Pipeline position
/// Sits between `SceneGateAdapter` and the rest of the Tier-0 pipeline.
/// Frames are forwarded to `downstream` **unconditionally** before inference.
///
/// ## Threading
/// Inference runs on a private serial `probeQueue` via `LandmarkOrchestratorProbe`.
/// Mutable state is guarded by `OSAllocatedUnfairLock`. Delegate methods are `nonisolated`.
///
/// ## Swift 6 concurrency
/// `@unchecked Sendable` — all shared mutable state is lock-protected.
public final class LandmarkOrchestrator: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Queues

    private let probeQueue = DispatchQueue(
        label: OrchestratorConstants.queueLabel,
        qos: .userInitiated
    )

    // MARK: - Cadence gating

    private let cadenceController: LandmarkCadenceController

    // MARK: - Downstream pipeline delegate

    /// Set once in `wireUp()` before inference begins; weak to avoid retain cycles.
    public weak var downstream: (any CameraFrameDelegate)?

    // MARK: - Inference helper

    private let probeImpl: LandmarkOrchestratorProbe

    // MARK: - Backpressure flag (I1)

    /// Prevents CVPixelBuffer pool exhaustion by dropping frames while inference runs.
    private let isBusy = OSAllocatedUnfairLock<Bool>(initialState: false)

    // MARK: - Monotonic timestamp guard

    private let lastTimestampLock: OSAllocatedUnfairLock<Int>

    // MARK: - Init

    /// Creates a `LandmarkOrchestrator`.
    ///
    /// Loads `hand_landmarker.task` and `face_landmarker.task` from `Bundle.main`.
    ///
    /// - Parameters:
    ///   - cadenceController: Rate-limits landmark inference to ≤5 fps.
    ///   - onBodySignal: Called on any thread when a merged `BodySignal` stabilises.
    /// - Throws: `MediaPipeLandmarkProbeError.modelNotFound` if a `.task` file is absent.
    public init(
        cadenceController: LandmarkCadenceController = LandmarkCadenceController(),
        onBodySignal: @escaping @Sendable (BodySignal) -> Void
    ) throws {
        self.cadenceController = cadenceController
        self.lastTimestampLock = OSAllocatedUnfairLock(initialState: 0)

        // --- Hand Landmarker ---
        guard let handModelPath = Bundle.main.path(
            forResource: "hand_landmarker", ofType: "task"
        ) else {
            throw MediaPipeLandmarkProbeError.modelNotFound("hand_landmarker.task")
        }
        let handOptions = HandLandmarkerOptions()
        handOptions.baseOptions.modelAssetPath = handModelPath
        handOptions.runningMode                = .video
        handOptions.minHandDetectionConfidence = OrchestratorConstants.minHandDetectionConfidence
        handOptions.minHandPresenceConfidence  = OrchestratorConstants.minHandPresenceConfidence
        handOptions.minTrackingConfidence      = OrchestratorConstants.handTrackingConfidence
        handOptions.numHands                   = OrchestratorConstants.maxHands
        let handLandmarker = try HandLandmarker(options: handOptions)

        // --- Face Landmarker ---
        guard let faceModelPath = Bundle.main.path(
            forResource: "face_landmarker", ofType: "task"
        ) else {
            throw MediaPipeLandmarkProbeError.modelNotFound("face_landmarker.task")
        }
        let faceOptions = FaceLandmarkerOptions()
        faceOptions.baseOptions.modelAssetPath = faceModelPath
        faceOptions.runningMode                = .video
        faceOptions.minFaceDetectionConfidence = OrchestratorConstants.minFaceDetectionConfidence
        faceOptions.minFacePresenceConfidence  = OrchestratorConstants.minFacePresenceConfidence
        faceOptions.minTrackingConfidence      = OrchestratorConstants.faceTrackingConfidence
        faceOptions.numFaces                   = OrchestratorConstants.maxFaces
        let faceLandmarker = try FaceLandmarker(options: faceOptions)

        self.probeImpl = LandmarkOrchestratorProbe(
            handLandmarker: handLandmarker,
            faceLandmarker: faceLandmarker,
            cadenceController: cadenceController,
            onBodySignal: onBodySignal
        )
    }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // 1. Forward unconditionally — never block Tier-0 frame delivery.
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        // 2. Strictly-increasing millisecond timestamp for MediaPipe .video mode.
        let timestampMs = lastTimestampLock.withLock { last -> Int in
            let ms   = Int(CMTimeGetSeconds(timestamp) * 1_000)
            let next = max(ms, last + OrchestratorConstants.minTimestampStepMs)
            last = next
            return next
        }

        // 3. Cheap cadence gate (timer + settle only, no Vision) — camera queue safe. (I2)
        guard cadenceController.checkCadence(isSettled: true) else { return }

        // 4. Drop-if-busy backpressure — prevents CVPixelBuffer pool exhaustion. (I1)
        guard isBusy.withLock({ busy in
            guard !busy else { return false }
            busy = true
            return true
        }) else { return }

        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        probeQueue.async { [weak self] in
            defer { self?.isBusy.withLock { $0 = false } }
            guard let self else { return }
            // Presence check + reset-or-inference all run on probeQueue (I2 + I3 fix).
            self.probeImpl.probe(pixelBuffer: wrapped.value, timestampMs: timestampMs)
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }
}
