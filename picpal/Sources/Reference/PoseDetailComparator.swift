import Foundation

enum PoseDetailComparator {
    private static func delta(_ target: PoseTarget, _ live: PoseDetailMeasurement) -> [Double] {
        zip(target.measurement.values, live.values).map { expected, actual in
            let difference = expected - actual
            return target.measurement.key == .handPosition || target.measurement.key == .fingerSpread
                ? difference : atan2(sin(difference), cos(difference))
        }
    }
    static func alignedDetails(profile: PoseTargetProfile, live: [PoseDetailMeasurement]) -> Set<PoseDetailKey> {
        Set(profile.targets.compactMap { target in
            guard let actual = live.first(where: { $0.key == target.measurement.key && $0.isAvailable }),
                  delta(target, actual).map({ abs($0) }).max()! <= target.tolerance else { return nil }
            return target.measurement.key
        })
    }
    static func compare(profile: PoseTargetProfile, live: [PoseDetailMeasurement]) -> [PoseDetailCandidate] {
        profile.targets.compactMap { target -> PoseDetailCandidate? in
            let key = target.measurement.key
            guard let actual = live.first(where: { $0.key == key && $0.isAvailable }) else { return nil }
            let differences = delta(target, actual)
            let error = differences.map { abs($0) }.max()! / target.tolerance
            guard error > 1 else { return nil }
            let d = differences[0]
            let text: String
            let direction: String
            switch key {
            case .handPosition:
                if abs(differences[1]) > abs(d) {
                    direction = differences[1] > 0 ? "up" : "down"
                    text = differences[1] > 0 ? "Raise your hand toward the reference position" : "Lower your hand toward the reference position"
                } else {
                    direction = d > 0 ? "right" : "left"
                    text = "Move your hand toward the \(direction) side of the preview"
                }
            case .fingerSpread:
                direction = d > 0 ? "wider" : "narrower"
                text = d > 0 ? "Spread your index and middle fingers slightly" : "Bring your index and middle fingers slightly closer together"
            case .headTilt:
                direction = d > 0 ? "left" : "right"
                text = abs(target.measurement.values[0]) < 0.1 ? "Straighten your head slightly" : "Tilt the top of your head toward the \(direction) side of the preview"
            case .headTurn:
                direction = d > 0 ? "positive" : "negative"
                let expected = target.measurement.values[0], value = actual.values[0]
                if expected * value < 0, abs(expected) > 0.15, abs(value) > 0.15 {
                    text = "Turn your face toward the opposite side, as in the reference"
                } else if abs(expected) < abs(value) { text = "Turn your face more directly toward the camera" }
                else { text = "Turn your face slightly farther from the camera to match the reference" }
            case .handRoll:
                direction = d > 0 ? "left" : "right"
                text = "Tilt the top of your hand toward the \(direction) side of the preview"
            case .shoulderTilt:
                direction = d > 0 ? "right" : "left"
                text = "Raise the shoulder on the \(direction) side of the preview slightly"
            }
            let confidence = min(target.measurement.confidence, actual.confidence)
            return PoseDetailCandidate(key: key, normalizedError: error, confidence: confidence,
                action: ReferenceAction(id: "\(key.evidenceKey)_\(direction)", dimension: .pose, actor: .subject,
                    direction: key.evidenceKey, instruction: text, expectedChange: "Match the visible detail in the reference", confidence: Double(confidence)), target: nil)
        }.sorted {
            let lhs = $0.normalizedError * Double($0.confidence), rhs = $1.normalizedError * Double($1.confidence)
            return lhs == rhs ? $0.key.rawValue < $1.key.rawValue : lhs > rhs
        }
    }
}
