import Foundation

struct PoseTarget: Sendable {
    let measurement: PoseDetailMeasurement
    let tolerance: Double
    let anchorLabel: String?
}

struct PoseTargetProfile: Sendable {
    let targets: [PoseTarget]
    let selected: Set<PoseDetailKey>
}

struct PoseDetailCandidate: Sendable {
    let key: PoseDetailKey
    let normalizedError: Double
    let confidence: Float
    let action: ReferenceAction
    let target: PoseGuidanceTarget?
}
