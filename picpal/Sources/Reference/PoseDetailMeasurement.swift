import Foundation
import Vision

public enum PoseDetailKey: String, Codable, CaseIterable, Sendable, Hashable {
    case handPosition, headTilt, headTurn, fingerSpread, handRoll, shoulderTilt

    public var evidenceKey: String {
        switch self {
        case .handPosition: "selfie_hand_position"
        case .headTilt: "selfie_head_tilt"
        case .headTurn: "selfie_head_turn"
        case .fingerSpread: "selfie_finger_spread"
        case .handRoll: "selfie_hand_roll"
        case .shoulderTilt: "selfie_shoulder_tilt"
        }
    }
}

/// Confidence describes input evidence quality, not a calibrated probability.
struct PoseDetailMeasurement: Sendable {
    let key: PoseDetailKey
    let values: [Double]
    let confidence: Float
    let observedAt: TimeInterval
    let unavailableReason: String?

    var isAvailable: Bool {
        unavailableReason == nil && confidence.isFinite && confidence >= 0.5 && confidence <= 1
            && observedAt.isFinite && values.count == (key == .handPosition ? 2 : 1)
            && values.allSatisfy(\.isFinite)
    }

    static func measure(selfie: SelfiePoseObservation?, face: CGRect?, joints: [String: LivePoseJoint],
                        geometry: ReferenceGeometry, at time: TimeInterval) -> [Self] {
        var output: [Self] = []
        func add(_ key: PoseDetailKey, _ values: [Double]?, _ confidence: Float = 0.85) {
            output.append(Self(key: key, values: values ?? [], confidence: values == nil ? 0 : confidence,
                               observedAt: time, unavailableReason: values == nil ? "Required landmarks unavailable or ambiguous" : nil))
        }
        add(.headTilt, selfie?.roll.map { [$0] }, selfie?.faceConfidence ?? 0)
        add(.headTurn, selfie?.yaw.map { [$0] }, selfie?.faceConfidence ?? 0)
        if let selfie, selfie.handsAvailable, selfie.detectedHandCount == 1, selfie.hands.count == 1,
           let face, ReferenceSession.validBox(face) {
            let hand = selfie.hands[0]
            let x = (hand.anchor.x - face.midX) / face.width
            let y = (hand.anchor.y - face.midY) / face.height
            let associated = x.isFinite && y.isFinite && abs(x) < 2.5 && abs(y) < 2.5
            add(.handPosition, associated ? [x, y] : nil, hand.confidence)
            add(.fingerSpread, associated ? hand.fingerSpread.map { [$0] } : nil, hand.spreadConfidence)
            add(.handRoll, associated ? hand.roll.map { [$0] } : nil, hand.rollConfidence)
        } else {
            add(.handPosition, nil); add(.fingerSpread, nil); add(.handRoll, nil)
        }
        let left = joints[VNHumanBodyPoseObservation.JointName.leftShoulder.rawValue.rawValue]
        let right = joints[VNHumanBodyPoseObservation.JointName.rightShoulder.rawValue.rawValue]
        if let left, let right, SelfiePoseTracker.valid(left.point, confidence: left.confidence),
           SelfiePoseTracker.valid(right.point, confidence: right.confidence) {
            let a = left.point.x < right.point.x ? left.point : right.point
            let b = left.point.x < right.point.x ? right.point : left.point
            let dx = (b.x - a.x) * geometry.imageAspectRatio
            let dy = b.y - a.y
            add(.shoulderTilt, dx > 0.04 ? [atan2(dy, dx)] : nil, min(left.confidence, right.confidence))
        } else { add(.shoulderTilt, nil) }
        return output
    }
}
