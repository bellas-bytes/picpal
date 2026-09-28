import Foundation

struct SelfiePoseComparison {
    var action: ReferenceAction?
    var target: PoseGuidanceTarget?
    var alignedDetails: Set<String> = []
    var measuredDetails = 0
    var availableDetails: Set<String> = []
}

/// Visible detail comparison does not certify a full pose or enable capture.
enum SelfiePoseComparator {
    static func compare(reference: ReferencePose, live: LivePoseObservation) -> SelfiePoseComparison {
        var result = SelfiePoseComparison()
        guard let expected = reference.selfie, let actual = live.selfie,
              let rf = reference.faceBox, let lf = live.faceBox,
              ReferenceSession.validBox(rf), ReferenceSession.validBox(lf) else { return result }
        func action(_ key: String, _ text: String) -> ReferenceAction {
            ReferenceAction(id: "selfie_\(key)", dimension: .pose, actor: .subject,
                direction: "selfie_\(key)", instruction: text,
                expectedChange: "Match the visible \(key.replacingOccurrences(of: "_", with: " ")) in the reference", confidence: 0.85)
        }
        // Exactly one visible hand prevents unstable cross-hand correspondence.
        if expected.handsAvailable, expected.detectedHandCount == 1, actual.detectedHandCount == 1,
           expected.hands.count == 1, actual.handsAvailable, actual.hands.count == 1 {
            let eh = expected.hands[0], ah = actual.hands[0]
            let e = CGPoint(x: (eh.anchor.x - rf.midX) / rf.width, y: (eh.anchor.y - rf.midY) / rf.height)
            let a = CGPoint(x: (ah.anchor.x - lf.midX) / lf.width, y: (ah.anchor.y - lf.midY) / lf.height)
            // Only coach hands near this face. Distant hands cannot be associated safely.
            if abs(e.x) < 2.5, abs(e.y) < 2.5, abs(a.x) < 2.5, abs(a.y) < 2.5 {
                result.measuredDetails += 1
                result.availableDetails.insert("selfie_hand_position")
                let dx = e.x - a.x, dy = e.y - a.y
                if max(abs(dx), abs(dy)) > 0.25 {
                    let text: String
                    if abs(dy) > abs(dx) { text = dy > 0 ? "Raise your hand toward the reference position" : "Lower your hand toward the reference position" }
                    else { text = dx > 0 ? "Move your hand toward the right side of the preview" : "Move your hand toward the left side of the preview" }
                    result.action = action("hand_position", text)
                    let p = live.geometry.displayPoint(CGPoint(x: lf.midX + e.x * lf.width, y: lf.midY + e.y * lf.height))
                    if (0...1).contains(p.x), (0...1).contains(p.y) {
                        result.target = PoseGuidanceTarget(point: CGPoint(x: p.x, y: 1 - p.y), label: "Reference hand position")
                    }
                } else { result.alignedDetails.insert("selfie_hand_position") }
                if eh.victory == true, let victory = ah.victory {
                    result.measuredDetails += 1
                    result.availableDetails.insert("selfie_gesture")
                    if victory { result.alignedDetails.insert("selfie_gesture") }
                    else if result.action == nil { result.action = action("gesture", "Make a V with your index and middle fingers; fold the other fingers") }
                }
            }
        }
        for (key, target, value, tolerance) in [("head_tilt", expected.roll, actual.roll, 0.15),
                                               ("head_turn", expected.yaw, actual.yaw, 0.20)] {
            guard let target, let value, target.isFinite, value.isFinite else { continue }
            result.measuredDetails += 1
            result.availableDetails.insert("selfie_\(key)")
            let delta = atan2(sin(target - value), cos(target - value))
            if abs(delta) <= tolerance { result.alignedDetails.insert("selfie_\(key)") }
            else if result.action == nil {
                let text: String
                if key == "head_tilt" {
                    text = abs(target) < 0.1 ? "Straighten your head slightly" :
                        (delta > 0 ? "Tilt the top of your head toward the left side of the preview" : "Tilt the top of your head toward the right side of the preview")
                } else if target * value < 0, abs(target) > 0.15, abs(value) > 0.15 {
                    text = "Turn your face toward the opposite side, as in the reference"
                } else if abs(target) < abs(value) {
                    text = "Turn your face more directly toward the camera"
                } else {
                    text = "Turn your face slightly farther from the camera to match the reference"
                }
                result.action = action(key, text)
            }
        }
        return result
    }
}
