import Foundation

struct SelfiePoseComparison {
    var action: ReferenceAction?
    var target: PoseGuidanceTarget?
    var alignedDetails: Set<String> = []
    var measuredDetails = 0
    var availableDetails: Set<String> = []
    var candidates: [PoseDetailCandidate] = []
}

/// Visible detail comparison does not certify a full pose or enable capture.
enum SelfiePoseComparator {
    static func measurements(reference: ReferencePose) -> [PoseDetailMeasurement] {
        PoseDetailMeasurement.measure(selfie: reference.selfie, face: reference.faceBox,
            joints: reference.bodyKeypoints.reduce(into: [String: LivePoseJoint]()) { output, entry in
                output[entry.key] = LivePoseJoint(point: entry.value, confidence: reference.jointConfidences[entry.key] ?? 0)
            }, geometry: reference.geometry, at: 0)
    }
    static func availableDetails(reference: ReferencePose) -> Set<PoseDetailKey> {
        guard reference.subjectCount == 1 else { return [] }
        var available = Set(measurements(reference: reference).filter(\.isAvailable).map(\.key))
        if available.contains(.handPosition), reference.selfie?.hands.first?.victory == true {
            available.insert(.fingerSpread)
        }
        return available
    }
    static func compare(reference: ReferencePose, live: LivePoseObservation,
                        selected: Set<PoseDetailKey> = Set(PoseDetailKey.allCases)) -> SelfiePoseComparison {
        var result = SelfiePoseComparison()
        guard reference.subjectCount == 1, live.subjectCount == 1, live.analysisAvailable else { return result }
        let profile = PoseTargetCompiler.compile(measurements: measurements(reference: reference), selected: selected)
        let actual = PoseDetailMeasurement.measure(selfie: live.selfie, face: live.faceBox, joints: live.joints,
                                                  geometry: live.geometry, at: live.capturedAt)
        result.candidates = PoseDetailComparator.compare(profile: profile, live: actual)
        result.alignedDetails = Set(PoseDetailComparator.alignedDetails(profile: profile, live: actual).map(\.evidenceKey))
        result.availableDetails = Set(profile.targets.compactMap { target in
            actual.contains { $0.key == target.measurement.key && $0.isAvailable } ? target.measurement.key.evidenceKey : nil
        })
        result.measuredDetails = result.availableDetails.count
        result.action = result.candidates.first?.action
        if let position = profile.targets.first(where: { $0.measurement.key == .handPosition })?.measurement.values,
           let face = live.faceBox {
            let p = live.geometry.displayPoint(CGPoint(x: face.midX + position[0] * face.width, y: face.midY + position[1] * face.height))
            if (0...1).contains(p.x), (0...1).contains(p.y) {
                let target = PoseGuidanceTarget(point: CGPoint(x: p.x, y: 1 - p.y), label: "Reference hand position")
                result.candidates = result.candidates.map { candidate in
                    PoseDetailCandidate(key: candidate.key, normalizedError: candidate.normalizedError,
                        confidence: candidate.confidence, action: candidate.action,
                        target: candidate.key == .handPosition ? target : nil)
                }
                result.target = result.candidates.first?.target
            }
        }
        // Preserve the conservative V-sign cue when full finger geometry is available.
        if selected.contains(.fingerSpread), measurements(reference: reference).contains(where: { $0.key == .handPosition && $0.isAvailable }),
           actual.contains(where: { $0.key == .handPosition && $0.isAvailable }),
           reference.selfie?.hands.first?.victory == true, let victory = live.selfie?.hands.first?.victory {
            result.measuredDetails += 1
            result.availableDetails.insert("selfie_gesture")
            if victory { result.alignedDetails.insert("selfie_gesture") }
            else if result.action == nil {
                result.action = ReferenceAction(id: "selfie_gesture", dimension: .pose, actor: .subject,
                    direction: "selfie_gesture", instruction: "Make a V with your index and middle fingers; fold the other fingers",
                    expectedChange: "Match the visible gesture in the reference", confidence: 0.85)
            }
        }
        return result
    }
}
