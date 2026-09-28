import Foundation

public struct PoseGuidanceTarget: Sendable, Equatable {
    /// Preview-display fractions, origin top-left. Never raw Vision coordinates.
    public let point: CGPoint
    public let label: String
}

public struct SelfieHandObservation: Sendable {
    public let anchor: CGPoint
    public let victory: Bool?
}

public struct SelfiePoseObservation: Sendable {
    public var yaw: Double?
    public var roll: Double?
    public var hands: [SelfieHandObservation]
    public var detectedHandCount: Int
    public var handsAvailable: Bool

    public init(yaw: Double? = nil, roll: Double? = nil,
                hands: [SelfieHandObservation] = [], handsAvailable: Bool = false, detectedHandCount: Int? = nil) {
        self.detectedHandCount = detectedHandCount ?? hands.count
        self.yaw = yaw; self.roll = roll; self.hands = hands; self.handsAvailable = handsAvailable
    }
}
