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

// MARK: - Merged signal state

private struct MergedState {
    var poseSignal: BodySignal?
    var handSignal: BodySignal?
    var gazeSignal: BodySignal?
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
/// Inference runs on a private serial `probeQueue`. Mutable state is guarded by
/// `OSAllocatedUnfairLock`. Delegate methods are `nonisolated`.
///
/// ## Swift 6 concurrency
/// `@unchecked Sendable` — all shared mutable state is lock-protected.
public final class LandmarkOrchestrator: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Queues and models

    private let probeQueue = DispatchQueue(
        label: OrchestratorConstants.queueLabel,
        qos: .userInitiated
    )

    /// Accessed exclusively from `probeQueue`.
    private let handLandmarker: HandLandmarker
    private let faceLandmarker: FaceLandmarker

    // MARK: - Cadence gating

    private let cadenceController: LandmarkCadenceController

    // MARK: - Downstream pipeline delegate

    /// Set once in `wireUp()` before inference begins; weak to avoid retain cycles.
    public weak var downstream: (any CameraFrameDelegate)?

    // MARK: - Signal producers

    private let bodyProducer: BodyPoseSignalProducer
    private let handProducer: HandObstructionSignalProducer
    private let gazeProducer: GazeSignalProducer

    // MARK: - Merged signal state

    private let stateLock: OSAllocatedUnfairLock<MergedState>
    private let onBodySignal: @Sendable (BodySignal) -> Void

    // MARK: - Monotonic timestamp guard

    private let lastTimestampLock: OSAllocatedUnfairLock<Int>

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.picpal", category: "LandmarkOrchestrator")

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
        self.cadenceController   = cadenceController
        self.onBodySignal        = onBodySignal
        self.lastTimestampLock   = OSAllocatedUnfairLock(initialState: 0)

        // Create the lock as a local so producers can capture it before self is ready.
        let lock = OSAllocatedUnfairLock(initialState: MergedState())
        self.stateLock = lock

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
        faceOptions.minFaceDetectionConfidence = OrchestratorConstants.minFaceDetectionConfidence
        faceOptions.minFacePresenceConfidence  = OrchestratorConstants.minFacePresenceConfidence
        faceOptions.minTrackingConfidence      = OrchestratorConstants.faceTrackingConfidence
        faceOptions.numFaces                   = OrchestratorConstants.maxFaces
        self.faceLandmarker = try FaceLandmarker(options: faceOptions)

        // --- Signal producers ---
        // Capture local copies so closures do not reference self before init completes.
        let capturedSignal = onBodySignal

        self.bodyProducer = BodyPoseSignalProducer { signal in
            let winner = lock.withLock { state -> BodySignal in
                state.poseSignal = signal
                return LandmarkOrchestrator.winner(from: state)
            }
            capturedSignal(winner)
        }
        self.handProducer = HandObstructionSignalProducer { signal in
            let winner = lock.withLock { state -> BodySignal in
                state.handSignal = signal
                return LandmarkOrchestrator.winner(from: state)
            }
            capturedSignal(winner)
        }
        self.gazeProducer = GazeSignalProducer { signal in
            let winner = lock.withLock { state -> BodySignal in
                state.gazeSignal = signal
                return LandmarkOrchestrator.winner(from: state)
            }
            capturedSignal(winner)
        }
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

        // 3. Cadence gate — SceneGateAdapter already guarantees isSettled.
        if cadenceController.shouldRunLandmarks(pixelBuffer: pixelBuffer, isSettled: true) {
            let wrapped = SendablePixelBuffer(value: pixelBuffer)
            probeQueue.async { [weak self] in
                self?.runInference(pixelBuffer: wrapped.value, timestampMs: timestampMs)
            }
        } else if !cadenceController.lastPresenceResult.personPresent {
            // No person detected: reset all producers so smoothers can fire .noPersonPresent.
            bodyProducer.process(observation: nil)
            handProducer.process(keypoints: [])
            gazeProducer.process(faceLandmarks: [])
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }

    // MARK: - Inference (runs on probeQueue)

    private func runInference(pixelBuffer: CVPixelBuffer, timestampMs: Int) {
        guard let mpImage = try? MPImage(pixelBuffer: pixelBuffer) else {
            logger.error("LandmarkOrchestrator: MPImage init failed")
            return
        }

        // a. Vision body pose
        let visionRequest = VNDetectHumanBodyPoseRequest()
        let visionHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]
        )
        do {
            try visionHandler.perform([visionRequest])
        } catch {
            logger.error("Body pose failed: \(error.localizedDescription, privacy: .public)")
        }
        bodyProducer.process(observation: visionRequest.results?.first)

        // b. MediaPipe hand landmarker
        do {
            let result = try handLandmarker.detect(
                videoFrame: mpImage, timestampInMilliseconds: timestampMs
            )
            let keypoints: [Keypoint] = result.landmarks.flatMap { hand in
                hand.map { lm in
                    Keypoint(
                        point: LandmarkCoordinates.mediapipePointToUIKit(
                            CGPoint(x: Double(lm.x), y: Double(lm.y))
                        ),
                        confidence: lm.visibility.map { Float(truncating: $0) }
                            ?? lm.presence.map { Float(truncating: $0) }
                            ?? 1.0
                    )
                }
            }
            handProducer.process(keypoints: keypoints)
        } catch {
            logger.error("Hand detect failed: \(error.localizedDescription, privacy: .public)")
            handProducer.process(keypoints: [])
        }

        // c. MediaPipe face landmarker
        do {
            let result = try faceLandmarker.detect(
                videoFrame: mpImage, timestampInMilliseconds: timestampMs
            )
            let landmarks: [Keypoint] = (result.faceLandmarks.first ?? []).map { lm in
                Keypoint(
                    point: LandmarkCoordinates.mediapipePointToUIKit(
                        CGPoint(x: Double(lm.x), y: Double(lm.y))
                    ),
                    confidence: lm.visibility.map { Float(truncating: $0) }
                        ?? lm.presence.map { Float(truncating: $0) }
                        ?? 1.0
                )
            }
            gazeProducer.process(faceLandmarks: landmarks)
        } catch {
            logger.error("Face detect failed: \(error.localizedDescription, privacy: .public)")
            gazeProducer.process(faceLandmarks: [])
        }
    }

    // MARK: - Signal merging

    /// Priority integer for each `BodyHint` (lower = more urgent).
    private static func bodyPriority(for hint: BodyHint) -> Int {
        switch hint {
        case .lensObstructed:    return 0
        case .awkwardCrop:       return 1
        case .gazeAway:          return 2
        case .nudgeDownHeadroom: return 3
        case .nudgeUpHeadroom:   return 4
        case .goodBody:          return 5
        }
    }

    /// Returns the highest-priority `BodySignal` across all source slots,
    /// or `.noPersonPresent` when every slot is nil.
    private static func winner(from state: MergedState) -> BodySignal {
        let candidates = [state.poseSignal, state.handSignal, state.gazeSignal]
            .compactMap { $0 }
        return candidates.min(by: {
            bodyPriority(for: $0.hint) < bodyPriority(for: $1.hint)
        }) ?? .noPersonPresent
    }
}
