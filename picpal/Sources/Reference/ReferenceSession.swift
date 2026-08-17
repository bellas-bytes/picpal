import UIKit
import Vision

// MARK: - ReferenceSessionError

/// Errors that can surface from pose-extraction operations.
enum ReferenceSessionError: Error {
    /// The image contains no detectable human body pose.
    case noPoseDetected
    /// The `UIImage` could not be converted to a `CGImage` for Vision processing.
    case imageConversionFailed
}

// MARK: - Private constants

/// Minimum confidence threshold for including a body keypoint.
private let keypointConfidenceThreshold: Float = 0.3

// MARK: - ReferenceSession

/// Owns the active reference photo and its extracted `ReferencePose`.
///
/// Create one when the user picks a reference image; call `extractPose()` to run
/// Vision body-pose and face analysis asynchronously. Discard the session when the
/// user dismisses the reference picker.
///
/// ## Threading
/// The class is `@MainActor`-isolated. All Vision work is dispatched to a detached
/// background task so the main thread is never blocked. The `visionExtractor` closure
/// must be `@Sendable` to satisfy Swift 6 strict concurrency.
@MainActor
final class ReferenceSession: ObservableObject {

    // MARK: - Published state

    /// The selected reference image. Immutable after init.
    let image: UIImage

    /// The extracted pose, set on completion of `extractPose()`. Nil if extraction is
    /// pending, failed, or returned no body.
    @Published private(set) var pose: ReferencePose?

    /// True while Vision inference is running; false otherwise.
    @Published private(set) var isExtracting: Bool = false

    // MARK: - Injectable extractor

    /// Closure that performs the actual Vision inference.
    ///
    /// Production code uses the default `ReferenceSession.runVision(on:)` implementation.
    /// Tests inject a fast mock that returns a fixed `ReferencePose?` without spawning
    /// Vision requests.
    private let visionExtractor: @Sendable (UIImage) -> ReferencePose?

    // MARK: - Init

    /// Creates a session for the given image.
    ///
    /// - Parameters:
    ///   - image: The reference photo selected by the user.
    ///   - visionExtractor: Replaces the production Vision implementation in tests.
    ///     Defaults to `ReferenceSession.runVision(on:)`.
    init(
        image: UIImage,
        visionExtractor: @escaping @Sendable (UIImage) -> ReferencePose? = ReferenceSession.runVision(on:)
    ) {
        self.image = image
        self.visionExtractor = visionExtractor
    }

    // MARK: - Pose extraction

    /// Runs Vision body-pose and face analysis on a detached background queue.
    ///
    /// Sets `isExtracting` to `true` for the duration of inference and `false` on
    /// completion (success or failure). Sets `pose` to the extracted `ReferencePose`, or
    /// `nil` if no human body was detected.
    func extractPose() async {
        isExtracting = true
        defer { isExtracting = false }
        // Capture values from the main actor before crossing the isolation boundary.
        let capturedImage = image
        let extractor = visionExtractor
        pose = await Task.detached(priority: .userInitiated) {
            extractor(capturedImage)
        }.value
    }

    // MARK: - Vision inference (nonisolated static — runs off main actor)

    /// Performs `VNDetectHumanBodyPoseRequest` and optionally `VNDetectFaceLandmarksRequest`
    /// on the given image. Returns a fully-populated `ReferencePose`, or `nil` if no body
    /// pose was detected.
    ///
    /// Declared `static` to prevent inadvertent capture of `self` inside the detached task.
    /// No Vision types leak into the returned `ReferencePose` — joint names are stored as
    /// their `rawValue` `String`s.
    nonisolated private static func runVision(on image: UIImage) -> ReferencePose? {
        guard let cgImage = image.cgImage else { return nil }

        // MARK: Body pose (required)

        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([bodyRequest])
        } catch {
            return nil
        }

        guard let bodyObservation = bodyRequest.results?.first else { return nil }

        // Map joint names to normalized CGPoints, filtering below confidence threshold.
        //
        // VNHumanBodyPoseObservation.JointName conforms to RawRepresentable where
        // RawValue is VNRecognizedPointKey (not String). VNRecognizedPointKey in turn
        // has a String rawValue. Two hops are needed to reach the plain String key:
        //   JointName → .rawValue → VNRecognizedPointKey → .rawValue → String
        let keypoints: [String: CGPoint]
        do {
            let allPoints = try bodyObservation.recognizedPoints(
                VNHumanBodyPoseObservation.JointsGroupName.all
            )
            keypoints = allPoints.reduce(into: [String: CGPoint]()) { dict, kv in
                if kv.value.confidence > keypointConfidenceThreshold {
                    dict[kv.key.rawValue.rawValue] = CGPoint(x: kv.value.x, y: kv.value.y)
                }
            }
        } catch {
            // Fall back: return nil when keypoints cannot be extracted.
            return nil
        }

        // Derive body bounding box from keypoints (more reliable than observation.boundingBox
        // for VNHumanBodyPoseObservation). All coordinates are in Vision normalized space
        // (origin bottom-left, y-axis pointing up).
        let xValues = keypoints.values.map(\.x)
        let yValues = keypoints.values.map(\.y)
        guard
            let minX = xValues.min(), let maxX = xValues.max(),
            let minY = yValues.min(), let maxY = yValues.max()
        else {
            return nil
        }
        let bodyBox = CGRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )

        // MARK: Face detection (optional)

        var faceCenter: CGPoint?
        var faceYaw: Float?
        var faceBox: CGRect?

        let faceRequest = VNDetectFaceLandmarksRequest()
        // Reuse the same handler for efficiency (image is already decoded).
        if (try? handler.perform([faceRequest])) != nil,
           let faceObservation = faceRequest.results?.first {
            let fb = faceObservation.boundingBox
            faceCenter = CGPoint(x: fb.midX, y: fb.midY)
            // VNFaceObservation.yaw: positive = face turned to the right (observer frame).
            faceYaw = faceObservation.yaw.map { Float($0.doubleValue) }
            faceBox = fb
        }

        // MARK: Subject bounding box

        // Union of body and face boxes (both present, or fall back to body only).
        let subjectBox: CGRect
        if let fb = faceBox {
            subjectBox = bodyBox.union(fb)
        } else {
            subjectBox = bodyBox
        }

        // In Vision coords (y-up), the top of the subject is the maximum Y value.
        // Headroom = space between the top of the subject and the top of the frame.
        let subjectCenterX = Float(subjectBox.midX)
        let subjectCenterY = Float(subjectBox.midY)
        let subjectHeightFraction = Float(subjectBox.height)
        let headroomFraction = Float(max(0, 1.0 - subjectBox.maxY))

        return ReferencePose(
            bodyKeypoints: keypoints,
            faceCenter: faceCenter,
            faceYaw: faceYaw,
            subjectBoundingBox: subjectBox,
            subjectCenterX: subjectCenterX,
            subjectCenterY: subjectCenterY,
            subjectHeightFraction: subjectHeightFraction,
            headroomFraction: headroomFraction
        )
    }
}
