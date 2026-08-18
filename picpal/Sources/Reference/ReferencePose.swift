import Foundation

/// Keypoints and composition extracted from a reference still image.
/// All coordinates are in Vision's normalized coordinate space (origin bottom-left, y up).
/// Convert to UIKit (origin top-left, y down) before display comparisons.
public struct ReferencePose: Sendable {
    /// Body joint positions. Nil joints were not detected at sufficient confidence.
    /// Keys are raw values of `VNHumanBodyPoseObservation.JointName`.
    public let bodyKeypoints: [String: CGPoint]

    /// Face centroid in normalized coordinates. Nil if no face detected.
    public let faceCenter: CGPoint?

    /// Estimated face yaw in radians. Positive = turned right. Nil if no face detected.
    public let faceYaw: Float?

    /// Bounding box of the primary subject (union of body + face bounds).
    public let subjectBoundingBox: CGRect

    /// Horizontal center of subject, normalized 0–1 (0 = left edge).
    public let subjectCenterX: Float

    /// Vertical center of subject, normalized 0–1 (0 = bottom edge, Vision coords).
    public let subjectCenterY: Float

    /// Subject height as a fraction of the frame height (proxy for distance / zoom).
    public let subjectHeightFraction: Float

    /// Space above subject to top of frame, normalized.
    public let headroomFraction: Float

    /// Creates a reference pose with all composition parameters.
    ///
    /// - Parameters:
    ///   - bodyKeypoints: Dictionary mapping joint names (raw values) to normalized positions
    ///   - faceCenter: Optional face centroid in normalized coordinates
    ///   - faceYaw: Optional face yaw in radians (positive = turned right)
    ///   - subjectBoundingBox: Bounding box of the subject
    ///   - subjectCenterX: Horizontal center (0–1, 0 = left)
    ///   - subjectCenterY: Vertical center (0–1, 0 = bottom)
    ///   - subjectHeightFraction: Height as fraction of frame height
    ///   - headroomFraction: Space above subject to top
    public init(
        bodyKeypoints: [String: CGPoint],
        faceCenter: CGPoint?,
        faceYaw: Float?,
        subjectBoundingBox: CGRect,
        subjectCenterX: Float,
        subjectCenterY: Float,
        subjectHeightFraction: Float,
        headroomFraction: Float
    ) {
        self.bodyKeypoints = bodyKeypoints
        self.faceCenter = faceCenter
        self.faceYaw = faceYaw
        self.subjectBoundingBox = subjectBoundingBox
        self.subjectCenterX = subjectCenterX
        self.subjectCenterY = subjectCenterY
        self.subjectHeightFraction = subjectHeightFraction
        self.headroomFraction = headroomFraction
    }
}
