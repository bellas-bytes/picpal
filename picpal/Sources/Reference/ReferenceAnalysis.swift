import Foundation

enum ReferenceDimension: String, Codable, Sendable, CaseIterable {
    case framing, pose, viewpoint, lighting, background
}

enum DimensionStatus: String, Codable, Sendable {
    case matched, different, unknown, notApplicable
}

enum ActionActor: String, Codable, Sendable { case photographer, subject }

/// App-owned identity; never decoded from model output.
struct ReferenceEnvelope: Sendable, Equatable {
    let sessionID: UUID
    let generation: UInt64
    let requestID: UUID
    let capturedAt: TimeInterval
    let geometryRevision: UInt64
}

struct ReferenceFeature: Codable, Sendable, Equatable {
    let dimension: ReferenceDimension
    let evidence: String
    let confidence: Double
    let applicable: Bool
}

struct ReferenceProfile: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let summary: String
    let features: [ReferenceFeature]
}

struct ReferenceAction: Codable, Sendable, Equatable {
    let id: String
    let dimension: ReferenceDimension
    let actor: ActionActor
    let direction: String
    let instruction: String
    let expectedChange: String
    let confidence: Double
}

struct ReferenceDimensionComparison: Codable, Sendable, Equatable {
    let dimension: ReferenceDimension
    let status: DimensionStatus
    let referenceEvidence: String
    let liveEvidence: String
    let confidence: Double
}

struct ReferenceComparison: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let dimensions: [ReferenceDimensionComparison]
    let action: ReferenceAction?
}

enum ReferenceAnalysisFailure: String, Sendable {
    case offline, budgetExhausted, invalidResponse, timedOut, serviceUnavailable
}

enum ReferenceAnalysisEvent: Sendable {
    case profile(ReferenceEnvelope, ReferenceProfile)
    case comparison(ReferenceEnvelope, ReferenceComparison)
    case unavailable(ReferenceEnvelope, ReferenceAnalysisFailure)
    case invalidated(ReferenceEnvelope)
}

/// Shared local comparison output. Unknown pose alignment is deliberately optional.
struct LocalReferenceEvidence: Sendable {
    let capturedAt: TimeInterval
    let geometryRevision: UInt64
    let framingAligned: Bool
    let poseAligned: Bool?
    let dimensions: [ReferenceDimensionComparison]
    let action: ReferenceAction?
    let subjectPresent: Bool
    let analysisAvailable: Bool
    let subjectCount: Int
    var guidanceTarget: PoseGuidanceTarget? = nil
    var progressCaption: String? = nil
    var availablePoseDetails: Set<String> = []
    var alignedPoseDetails: Set<String> = []
    var framingDomain: ReferenceFramingDomain = .person
    var poseCandidates: [PoseDetailCandidate] = []
    var selectedPoseDetails: Set<PoseDetailKey> = Set(PoseDetailKey.allCases)
}
