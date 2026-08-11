import CoreGraphics
import Vision

// MARK: - BodyPoseAnalyzer

/// Pure geometry analyzer that processes `VNHumanBodyPoseObservation` keypoints
/// and emits a `BodySignal` describing awkward-crop and headroom quality.
///
/// ## Threading
/// All stored properties are immutable after initialisation — no lock is needed.
/// `BodyPoseAnalyzer` is declared `@unchecked Sendable` so it can be stored and
/// shared by the pipeline components that are themselves `@unchecked Sendable`.
///
/// ## Testing
/// `VNHumanBodyPoseObservation` cannot be constructed in unit tests (Vision private
/// initialiser). Call `analyzeKeypoints(_:frameSize:)` directly with synthetic
/// `[JointName: Keypoint]` dictionaries instead.
public final class BodyPoseAnalyzer: @unchecked Sendable {

    // MARK: - Constants

    /// Keypoint confidence floor applied when filtering body joints.
    public static let defaultJointConfidenceFloor: Float = 0.5

    /// Fraction of frame height/width that defines the crop danger zone at each edge.
    public static let defaultCropMargin: Double = 0.05

    /// Fraction of frame height above the head considered ideal headroom.
    public static let defaultIdealHeadroomFraction: Double = 0.10

    /// Tolerance on either side of `defaultIdealHeadroomFraction` before a nudge cue fires.
    public static let defaultHeadroomTolerance: Double = 0.05

    private enum JointGroup {
        /// Joints watched for proximity to any frame edge (awkward-crop detection).
        static let cropWatch: [VNHumanBodyPoseObservation.JointName] = [
            .leftWrist, .rightWrist,
            .leftElbow, .rightElbow,
            .leftAnkle, .rightAnkle,
            .leftKnee, .rightKnee,
            .neck,
        ]

        /// Head-top proxy candidates; highest-confidence passing joint is used.
        static let headProxies: [VNHumanBodyPoseObservation.JointName] = [.nose, .neck]
    }

    // MARK: - Configuration (immutable)

    private let jointConfidenceFloor: Float
    private let cropMargin: Double
    private let idealHeadroomFraction: Double
    private let headroomTolerance: Double

    // MARK: - Init

    public init(
        jointConfidenceFloor: Float = BodyPoseAnalyzer.defaultJointConfidenceFloor,
        cropMargin: Double = BodyPoseAnalyzer.defaultCropMargin,
        idealHeadroomFraction: Double = BodyPoseAnalyzer.defaultIdealHeadroomFraction,
        headroomTolerance: Double = BodyPoseAnalyzer.defaultHeadroomTolerance
    ) {
        self.jointConfidenceFloor = jointConfidenceFloor
        self.cropMargin = cropMargin
        self.idealHeadroomFraction = idealHeadroomFraction
        self.headroomTolerance = headroomTolerance
    }

    // MARK: - Public API

    /// Analyse a single body-pose observation and return a `BodySignal`.
    ///
    /// Vision points are converted to UIKit coordinates before any geometry.
    ///
    /// - Parameters:
    ///   - observation: From `VNDetectHumanBodyPoseRequest.results`.
    ///   - frameSize: Normalised frame dimensions. Use `CGSize(width: 1, height: 1)`
    ///     for normalised-coordinate geometry (the typical production path).
    /// - Returns: A `BodySignal`, or `nil` if all keypoints are below
    ///   `jointConfidenceFloor`.
    public func analyze(
        observation: VNHumanBodyPoseObservation,
        frameSize: CGSize = CGSize(width: 1, height: 1)
    ) -> BodySignal? {
        let keypoints = extractKeypoints(from: observation)
        return analyzeKeypoints(keypoints, frameSize: frameSize)
    }

    // MARK: - Internal (exposed for unit tests)

    /// Geometry-only entry point — accepts a pre-built keypoint dictionary.
    ///
    /// Declared `internal` (not `private`) so unit tests can call it directly
    /// with synthetic `Keypoint` values, bypassing Vision observation construction.
    ///
    /// - Parameters:
    ///   - keypoints: Keypoints in UIKit-normalised coordinates (top-left origin, 0–1).
    ///   - frameSize: Dimensions of the frame the keypoints refer to.
    /// - Returns: A `BodySignal`, or `nil` if no keypoint meets the confidence floor.
    func analyzeKeypoints(
        _ keypoints: [VNHumanBodyPoseObservation.JointName: Keypoint],
        frameSize: CGSize
    ) -> BodySignal? {
        guard keypoints.values.contains(where: { $0.confidence >= jointConfidenceFloor }) else {
            return nil
        }
        if let cropSignal = checkCrop(keypoints: keypoints, frameSize: frameSize) {
            return cropSignal
        }
        return checkHeadroom(keypoints: keypoints, frameSize: frameSize)
    }

    // MARK: - Private: keypoint extraction

    private func extractKeypoints(
        from observation: VNHumanBodyPoseObservation
    ) -> [VNHumanBodyPoseObservation.JointName: Keypoint] {
        var result: [VNHumanBodyPoseObservation.JointName: Keypoint] = [:]
        // Build the union of crop-watch joints and head-proxy joints.
        let candidates = JointGroup.cropWatch + JointGroup.headProxies
        for joint in candidates {
            guard let recognized = try? observation.recognizedPoint(joint) else { continue }
            // Convert Vision coords (bottom-left origin) → UIKit (top-left origin).
            let uiKitPoint = LandmarkCoordinates.visionPointToUIKit(recognized.location)
            result[joint] = Keypoint(point: uiKitPoint, confidence: recognized.confidence)
        }
        return result
    }

    // MARK: - Private: crop detection

    private func checkCrop(
        keypoints: [VNHumanBodyPoseObservation.JointName: Keypoint],
        frameSize: CGSize
    ) -> BodySignal? {
        for joint in JointGroup.cropWatch {
            guard
                let kp = keypoints[joint],
                let filtered = KeypointFilter.filter(kp, floor: jointConfidenceFloor)
            else { continue }

            if isNearEdge(point: filtered.point, frameSize: frameSize) {
                return BodySignal(
                    hint: .awkwardCrop,
                    confidence: filtered.confidence,
                    dominantRect: nil
                )
            }
        }
        return nil
    }

    /// Returns `true` when `point` lies within `cropMargin` of any frame edge.
    ///
    /// Geometry uses normalised fractions so the check is independent of whether
    /// `frameSize` is (1, 1) or actual pixel dimensions.
    private func isNearEdge(point: CGPoint, frameSize: CGSize) -> Bool {
        let nx = point.x / frameSize.width
        let ny = point.y / frameSize.height
        let margin = cropMargin
        return ny < margin
            || ny > 1.0 - margin
            || nx < margin
            || nx > 1.0 - margin
    }

    // MARK: - Private: headroom

    private func checkHeadroom(
        keypoints: [VNHumanBodyPoseObservation.JointName: Keypoint],
        frameSize: CGSize
    ) -> BodySignal {
        // Pick the head-proxy joint with the highest confidence that passes the floor.
        let headProxy = JointGroup.headProxies
            .compactMap { joint -> Keypoint? in
                guard let kp = keypoints[joint] else { return nil }
                return KeypointFilter.filter(kp, floor: jointConfidenceFloor)
            }
            .max(by: { $0.confidence < $1.confidence })

        guard let head = headProxy else {
            // No usable head joint — cannot assess headroom; signal all-clear.
            return BodySignal(hint: .goodBody, confidence: 0, dominantRect: nil)
        }

        // currentHeadroom: UIKit Y normalised to frame height.
        // Smaller value → head closer to the top of the frame.
        let currentHeadroom = head.point.y / frameSize.height
        let lowerBound = idealHeadroomFraction - headroomTolerance
        let upperBound = idealHeadroomFraction + headroomTolerance

        if currentHeadroom < lowerBound {
            // Too close to top — subject needs to move down in frame.
            return BodySignal(hint: .nudgeDownHeadroom, confidence: head.confidence, dominantRect: nil)
        } else if currentHeadroom > upperBound {
            // Too far from top — frame needs to move up (or subject up).
            return BodySignal(hint: .nudgeUpHeadroom, confidence: head.confidence, dominantRect: nil)
        } else {
            return BodySignal(hint: .goodBody, confidence: head.confidence, dominantRect: nil)
        }
    }
}
