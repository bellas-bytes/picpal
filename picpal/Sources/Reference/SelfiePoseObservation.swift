import Foundation

public struct PoseGuidanceTarget: Sendable, Equatable {
    /// Preview-display fractions, origin top-left. Never raw Vision coordinates.
    public let point: CGPoint
    public let label: String
}

public struct SelfieHandObservation: Sendable {
    public let anchor: CGPoint
    public let victory: Bool?
    public let confidence: Float
    public let fingerSpread: Double?
    public let roll: Double?
    public let spreadConfidence: Float
    public let rollConfidence: Float
    let joints: [String: LivePoseJoint]

    init(anchor: CGPoint, victory: Bool?, confidence: Float = 0.85,
         fingerSpread: Double? = nil, roll: Double? = nil,
         spreadConfidence: Float = 0.85, rollConfidence: Float = 0.85,
         joints: [String: LivePoseJoint] = [:]) {
        self.anchor = anchor; self.victory = victory; self.confidence = confidence
        self.fingerSpread = fingerSpread; self.roll = roll
        self.spreadConfidence = spreadConfidence; self.rollConfidence = rollConfidence
        self.joints = joints
    }
}

public struct SelfiePoseObservation: Sendable {
    public var faceConfidence: Float
    public var yaw: Double?
    public var roll: Double?
    public var hands: [SelfieHandObservation]
    public var detectedHandCount: Int
    public var handsAvailable: Bool

    public init(yaw: Double? = nil, roll: Double? = nil,
                hands: [SelfieHandObservation] = [], handsAvailable: Bool = false, detectedHandCount: Int? = nil, faceConfidence: Float = 0.85) {
        self.faceConfidence = faceConfidence
        self.detectedHandCount = detectedHandCount ?? hands.count
        self.yaw = yaw; self.roll = roll; self.hands = hands; self.handsAvailable = handsAvailable
    }
}
