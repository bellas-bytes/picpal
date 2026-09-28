import Foundation

enum ReferenceCoachingPhase: String, Sendable, Equatable {
    case reading, localOnly, comparing, guiding, verifying, matched, unavailable, unsupported
}

enum ReferenceCloudAvailability: Sendable, Equatable {
    case localOnly
    case available
    case unavailable(ReferenceAnalysisFailure)
}

struct ReferenceCoachingInput: Sendable {
    var sessionID: UUID
    var generation: UInt64
    var geometryRevision: UInt64
    var now: TimeInterval
    var local: LocalReferenceEvidence?
    var profile: (envelope: ReferenceEnvelope, value: ReferenceProfile)? = nil
    var comparison: (envelope: ReferenceEnvelope, value: ReferenceComparison)? = nil
    var cloudAvailability: ReferenceCloudAvailability
    var captureSafe: Bool
}

struct ReferenceCoachingDecision: Sendable, Equatable {
    let phase: ReferenceCoachingPhase
    let caption: String
    let explanation: String?
    let action: ReferenceAction?
    let framingAligned: Bool
    let referenceMatched: Bool
    var guidanceTarget: PoseGuidanceTarget? = nil
    var progressCaption: String? = nil
    let allowsAutoCapture: Bool
}
