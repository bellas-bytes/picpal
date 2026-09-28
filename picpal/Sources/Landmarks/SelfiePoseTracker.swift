import Foundation
import Vision

/// Independent hand evidence. Detection failure never erases usable face evidence.
enum SelfiePoseTracker {
    static func detect(handler: VNImageRequestHandler, face: VNFaceObservation?, imageAspectRatio: Double) -> SelfiePoseObservation {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        let available = (try? handler.perform([request])) != nil
        let hands = (request.results ?? []).compactMap { observation -> SelfieHandObservation? in
            guard let points = try? observation.recognizedPoints(.all) else { return nil }
            let joints = Dictionary(uniqueKeysWithValues: points.map {
                ($0.key.rawValue.rawValue, LivePoseJoint(point: $0.value.location, confidence: $0.value.confidence))
            })
            return adapt(joints, imageAspectRatio: imageAspectRatio)
        }
        return SelfiePoseObservation(yaw: face?.yaw?.doubleValue, roll: face?.roll?.doubleValue,
                                    hands: hands, handsAvailable: available, detectedHandCount: request.results?.count ?? 0, faceConfidence: face?.confidence ?? 0)
    }

    static func adapt(_ joints: [String: LivePoseJoint], imageAspectRatio: Double) -> SelfieHandObservation? {
        typealias J = VNHumanHandPoseObservation.JointName
        guard let index = joints[J.indexMCP.rawValue.rawValue], let middle = joints[J.middleMCP.rawValue.rawValue],
              valid(index.point, confidence: index.confidence), valid(middle.point, confidence: middle.confidence) else { return nil }
        let anchor = CGPoint(x: (index.point.x + middle.point.x) / 2, y: (index.point.y + middle.point.y) / 2)
        func joint(_ name: J) -> LivePoseJoint? {
            guard let value = joints[name.rawValue.rawValue], valid(value.point, confidence: value.confidence) else { return nil }
            return value
        }
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot((a.x - b.x) * imageAspectRatio, a.y - b.y)
        }
        var spread: Double?
        var spreadConfidence: Float = 0
        if imageAspectRatio.isFinite, imageAspectRatio > 0,
           let little = joint(.littleMCP), let indexTip = joint(.indexTip), let middleTip = joint(.middleTip) {
            let width = distance(index.point, little.point)
            if width > 0.005 {
                spread = distance(indexTip.point, middleTip.point) / width
                spreadConfidence = min(index.confidence, little.confidence, indexTip.confidence, middleTip.confidence)
            }
        }
        var roll: Double?
        var rollConfidence: Float = 0
        if imageAspectRatio.isFinite, imageAspectRatio > 0, let wrist = joint(.wrist), distance(wrist.point, anchor) > 0.005 {
            roll = atan2(-(anchor.x - wrist.point.x) * imageAspectRatio, anchor.y - wrist.point.y)
            rollConfidence = min(wrist.confidence, index.confidence, middle.confidence)
        }
        return SelfieHandObservation(anchor: anchor, victory: victory(joints, imageAspectRatio: imageAspectRatio),
            confidence: min(index.confidence, middle.confidence), fingerSpread: spread, roll: roll,
            spreadConfidence: spreadConfidence, rollConfidence: rollConfidence, joints: joints)
    }

    static func valid(_ p: CGPoint, confidence: Float) -> Bool {
        confidence.isFinite && confidence >= 0.5 && p.x.isFinite && p.y.isFinite
            && p.x > 0.015 && p.x < 0.985 && p.y > 0.015 && p.y < 0.985
    }

    /// Conservative visible-finger geometry, not a general gesture classifier.
    static func victory(_ joints: [String: LivePoseJoint], imageAspectRatio: Double = 1) -> Bool? {
        typealias J = VNHumanHandPoseObservation.JointName
        func point(_ name: J) -> CGPoint? {
            guard let j = joints[name.rawValue.rawValue], valid(j.point, confidence: j.confidence) else { return nil }
            return CGPoint(x: j.point.x * imageAspectRatio, y: j.point.y)
        }
        guard let wrist = point(.wrist) else { return nil }
        func extended(_ base: J, _ middle: J, _ tip: J) -> Bool? {
            guard let a = point(base), let b = point(middle), let c = point(tip) else { return nil }
            let u = CGPoint(x: a.x - b.x, y: a.y - b.y)
            let v = CGPoint(x: c.x - b.x, y: c.y - b.y)
            let lengths = hypot(u.x, u.y) * hypot(v.x, v.y)
            guard lengths > 0.0001 else { return nil }
            let cosine = (u.x * v.x + u.y * v.y) / lengths
            let reaches = hypot(c.x - wrist.x, c.y - wrist.y) / max(0.001, hypot(b.x - wrist.x, b.y - wrist.y))
            if cosine < -0.75 && reaches > 1.12 { return true }
            if reaches < 0.85 { return false }
            return nil
        }
        guard let index = extended(.indexMCP, .indexPIP, .indexTip),
              let middle = extended(.middleMCP, .middlePIP, .middleTip),
              let ring = extended(.ringMCP, .ringPIP, .ringTip),
              let little = extended(.littleMCP, .littlePIP, .littleTip) else { return nil }
        guard index && middle && !ring && !little else { return false }
        guard let indexBase = point(.indexMCP), let middleBase = point(.middleMCP),
              let indexTip = point(.indexTip), let middleTip = point(.middleTip) else { return nil }
        let baseSpread = hypot(indexBase.x - middleBase.x, indexBase.y - middleBase.y)
        let tipSpread = hypot(indexTip.x - middleTip.x, indexTip.y - middleTip.y)
        guard baseSpread > 0.005 else { return nil }
        return tipSpread > baseSpread * 1.5 ? true : nil
    }
}
