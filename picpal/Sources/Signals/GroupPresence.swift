import CoreGraphics
import Foundation

/// Group-level framing geometry. Populated when ≥2 persons are detected.
public struct GroupPresence: Sendable {

    /// Number of detected persons with sufficient confidence.
    public let personCount: Int

    /// Union bounding box of all detected persons, normalized (Vision coords, y-up).
    public let unionBoundingBox: CGRect

    /// Fraction of frame width occupied by the group.
    public let spreadFraction: Float

    /// Normalized distance from left edge of union box to left frame edge.
    public let leftMargin: Float

    /// Normalized distance from right frame edge to right edge of union box.
    public let rightMargin: Float

    /// Normalized headroom above the union box.
    public let headroomFraction: Float

    public static let minPersonCount: Int = 2
    public static let edgeCutoffThreshold: Float = 0.04
    public static let spreadWideThreshold: Float = 0.80
    public static let learnInThreshold: Float = 0.35
    public static let highGroupThreshold: Float = 0.12
}
