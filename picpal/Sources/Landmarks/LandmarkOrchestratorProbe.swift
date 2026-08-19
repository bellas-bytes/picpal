import CoreVideo
import MediaPipeTasksVision
import os
import Vision

// MARK: - Merged signal state

private struct MergedState {
    var poseSignal: BodySignal?
    var handSignal: BodySignal?
    var gazeSignal: BodySignal?
}

// MARK: - LandmarkOrchestratorProbe

/// Runs presence gating, reset, and body/hand/face inference for `LandmarkOrchestrator`.
///
/// Executes exclusively on `LandmarkOrchestrator`'s private serial `probeQueue`.
///
/// ## Swift 6 concurrency
/// `@unchecked Sendable` --- all shared mutable state is lock-protected.
final class LandmarkOrchestratorProbe: @unchecked Sendable {

    private let handLandmarker: HandLandmarker
    private let faceLandmarker: FaceLandmarker
    private let cadenceController: LandmarkCadenceController
    private let bodyProducer: BodyPoseSignalProducer
    private let handProducer: HandObstructionSignalProducer
    private let gazeProducer: GazeSignalProducer
    private let stateLock: OSAllocatedUnfairLock<MergedState>
    private let capturedGroupPresence: @Sendable (GroupPresence?) -> Void
    private let logger = Logger(subsystem: "com.picpal", category: "LandmarkOrchestrator")

    // MARK: - Init

    init(
        handLandmarker: HandLandmarker,
        faceLandmarker: FaceLandmarker,
        cadenceController: LandmarkCadenceController,
        onBodySignal: @escaping @Sendable (BodySignal) -> Void,
        onGroupPresence: @escaping @Sendable (GroupPresence?) -> Void
    ) {
        self.handLandmarker    = handLandmarker
        self.faceLandmarker    = faceLandmarker
        self.cadenceController = cadenceController
        self.capturedGroupPresence = onGroupPresence

        let lock = OSAllocatedUnfairLock(initialState: MergedState())
        self.stateLock = lock
        let capturedSignal = onBodySignal

        self.bodyProducer = BodyPoseSignalProducer { signal in
            let winner = lock.withLock { state -> BodySignal in
                state.poseSignal = signal
                return LandmarkOrchestratorProbe.winner(from: state)
            }
            let rect = cadenceController.lastPresenceResult.dominantRect
            capturedSignal(BodySignal(hint: winner.hint, confidence: winner.confidence, dominantRect: rect))
        }
        self.handProducer = HandObstructionSignalProducer { signal in
            let winner = lock.withLock { state -> BodySignal in
                state.handSignal = signal
                return LandmarkOrchestratorProbe.winner(from: state)
            }
            let rect = cadenceController.lastPresenceResult.dominantRect
            capturedSignal(BodySignal(hint: winner.hint, confidence: winner.confidence, dominantRect: rect))
        }
        self.gazeProducer = GazeSignalProducer { signal in
            let winner = lock.withLock { state -> BodySignal in
                state.gazeSignal = signal
                return LandmarkOrchestratorProbe.winner(from: state)
            }
            let rect = cadenceController.lastPresenceResult.dominantRect
            capturedSignal(BodySignal(hint: winner.hint, confidence: winner.confidence, dominantRect: rect))
        }
    }

    // MARK: - Probe (called from probeQueue)

    /// Presence gate + inference-or-reset dispatch.
    ///
    /// Moving both the presence check and the producer reset onto `probeQueue`
    /// keeps AVFoundation frame delivery unblocked (I2) and eliminates the
    /// camera-queue/probeQueue race on producer state (I3).
    func probe(pixelBuffer: CVPixelBuffer, timestampMs: Int) {
        guard cadenceController.runPresenceCheck(pixelBuffer: pixelBuffer) else {
            bodyProducer.process(observation: nil)
            handProducer.process(keypoints: [])
            gazeProducer.process(faceLandmarks: [])
            capturedGroupPresence(nil)
            return
        }
        runInference(pixelBuffer: pixelBuffer, timestampMs: timestampMs)
    }

    // MARK: - Inference (called from probeQueue)

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

        // Group presence from all observations (not just .first).
        let groupPresence = GroupPresenceDetector().detect(from: visionRequest.results ?? [])
        capturedGroupPresence(groupPresence)

        // b. MediaPipe hand landmarker
        do {
            let result = try handLandmarker.detect(
                videoFrame: mpImage, timestampInMilliseconds: timestampMs
            )
            let keypoints: [Keypoint] = result.landmarks.flatMap { hand in
                hand.map { lm in
                    // I4: MediaPipe Tasks does not populate per-landmark visibility/presence;
                    // detector-level confidence gates (minHandDetectionConfidence etc.) are
                    // the effective floor. KeypointFilter is still correct for Vision paths.
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
                // I4: MediaPipe Tasks does not populate per-landmark visibility/presence;
                // detector-level confidence gates (minFaceDetectionConfidence etc.) are
                // the effective floor. KeypointFilter is still correct for Vision paths.
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

    private static func winner(from state: MergedState) -> BodySignal {
        let candidates = [state.poseSignal, state.handSignal, state.gazeSignal]
            .compactMap { $0 }
        return candidates.min(by: {
            bodyPriority(for: $0.hint) < bodyPriority(for: $1.hint)
        }) ?? .noPersonPresent
    }
}
