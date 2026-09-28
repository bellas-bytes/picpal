import Foundation

public enum ReferenceFramingDomain: Sendable { case person, face }

public enum PoseTrackingBackend: Sendable { case vision, mediaPipe }

/// Keypoints and composition extracted from a reference still image.
/// All coordinates are in Vision's normalized coordinate space (origin bottom-left, y up).
/// Convert to UIKit (origin top-left, y down) before display comparisons.
public struct ReferencePose: Sendable {
    /// Body joint positions. Nil joints were not detected at sufficient confidence.
    /// Keys are raw values of `VNHumanBodyPoseObservation.JointName`.
    public let bodyKeypoints: [String: CGPoint]
    public let jointConfidences: [String: Float]
    public let geometry: ReferenceGeometry
    public let subjectCount: Int
    public let trackingBackend: PoseTrackingBackend

    /// Face centroid in normalized coordinates. Nil if no face detected.
    public let selfie: SelfiePoseObservation?
    public let faceBox: CGRect?
    public let framingDomain: ReferenceFramingDomain

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
        headroomFraction: Float,
        jointConfidences: [String: Float]? = nil,
        geometry: ReferenceGeometry = ReferenceGeometry(),
        subjectCount: Int = 1,
        trackingBackend: PoseTrackingBackend = .vision,
        faceBox: CGRect? = nil, framingDomain: ReferenceFramingDomain = .person,
        selfie: SelfiePoseObservation? = nil
    ) {
        self.bodyKeypoints = bodyKeypoints
        self.jointConfidences = jointConfidences ?? bodyKeypoints.mapValues { _ in 1 }
        self.geometry = geometry
        self.subjectCount = subjectCount
        self.trackingBackend = trackingBackend
        self.selfie = selfie
        self.faceBox = faceBox
        self.framingDomain = framingDomain
        self.faceCenter = faceCenter
        self.faceYaw = faceYaw
        self.subjectBoundingBox = subjectBoundingBox
        self.subjectCenterX = subjectCenterX
        self.subjectCenterY = subjectCenterY
        self.subjectHeightFraction = subjectHeightFraction
        self.headroomFraction = headroomFraction
    }
}
