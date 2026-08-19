import Foundation

/// Per-frame difference between a ReferencePose and the live landmark output.
/// All fields are in normalized frame units; positive values indicate the live view
/// has too much of the named property relative to the reference.
public struct PoseDelta: Sendable {
    /// Threshold below which each component is considered matched.
    public static let defaultMatchThreshold: Float = 0.08

    /// Threshold for scale (looser — framing distance is harder to match exactly).
    public static let defaultScaleMatchThreshold: Float = 0.15

    /// Threshold for face yaw delta in radians.
    private static let defaultFaceYawThreshold: Float = 0.15

    /// Subject is too far right in live view (+) or too far left (-).
    public let horizontalOffset: Float

    /// Subject is too high in live view (+) or too low (-).
    public let verticalOffset: Float

    /// Live view has more headroom than reference (+) or less (-).
    public let headroomDelta: Float

    /// Subject is smaller in live view than reference (+) → too far away; negative → too close.
    public let scaleDelta: Float

    /// Face yaw delta (radians). Positive = more turned-right in live view. Nil if no face in either.
    public let faceYawDelta: Float?

    /// True when all components are within their thresholds.
    public var isWithinThreshold: Bool {
        abs(horizontalOffset) < Self.defaultMatchThreshold &&
        abs(verticalOffset) < Self.defaultMatchThreshold &&
        abs(headroomDelta) < Self.defaultMatchThreshold &&
        abs(scaleDelta) < Self.defaultScaleMatchThreshold &&
        (faceYawDelta.map { abs($0) < Self.defaultFaceYawThreshold } ?? true)
    }

    /// Creates a pose delta with all offset measurements.
    ///
    /// - Parameters:
    ///   - horizontalOffset: Horizontal center offset from reference
    ///   - verticalOffset: Vertical center offset from reference
    ///   - headroomDelta: Difference in headroom fraction
    ///   - scaleDelta: Difference in subject height fraction
    ///   - faceYawDelta: Optional face yaw difference in radians
    public init(
        horizontalOffset: Float,
        verticalOffset: Float,
        headroomDelta: Float,
        scaleDelta: Float,
        faceYawDelta: Float? = nil
    ) {
        self.horizontalOffset = horizontalOffset
        self.verticalOffset = verticalOffset
        self.headroomDelta = headroomDelta
        self.scaleDelta = scaleDelta
        self.faceYawDelta = faceYawDelta
    }
}
