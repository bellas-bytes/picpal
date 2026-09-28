import Foundation

struct ReferenceCoachingPolicy: Sendable {
    var comparisonMaxAge: TimeInterval = 8
    var localMaxAge: TimeInterval = 1
    var maximumObservationGap: TimeInterval = 0.75
    var alignmentDwell: TimeInterval = 1.5
    var minimumConfidence: Double = 0.65

    func fresh(_ timestamp: TimeInterval, now: TimeInterval, maximumAge: TimeInterval) -> Bool {
        timestamp.isFinite && now.isFinite && timestamp <= now && now - timestamp <= maximumAge
    }

    func supported(_ dimension: ReferenceDimensionComparison) -> Bool {
        dimension.confidence.isFinite && dimension.confidence >= minimumConfidence && dimension.confidence <= 1
            && !dimension.referenceEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !dimension.liveEvidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func supported(_ action: ReferenceAction, dimensions: [ReferenceDimensionComparison]) -> Bool {
        action.confidence.isFinite && action.confidence >= minimumConfidence && action.confidence <= 1
            && !action.direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !action.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && dimensions.contains { $0.dimension == action.dimension && $0.status == .different && supported($0) }
    }

    func allMatched(profile: ReferenceProfile, comparison: ReferenceComparison) -> Bool {
        guard profile.schemaVersion == 1, comparison.schemaVersion == 1, comparison.action == nil,
              profile.features.count == ReferenceDimension.allCases.count,
              comparison.dimensions.count == ReferenceDimension.allCases.count else { return false }
        for dimension in ReferenceDimension.allCases {
            let features = profile.features.filter { $0.dimension == dimension }
            let comparisons = comparison.dimensions.filter { $0.dimension == dimension }
            guard features.count == 1, comparisons.count == 1,
                  let feature = features.first, let observed = comparisons.first,
                  feature.confidence.isFinite, feature.confidence >= minimumConfidence, feature.confidence <= 1,
                  !feature.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if feature.applicable {
                guard observed.status == .matched, supported(observed) else { return false }
            } else {
                guard observed.status == .notApplicable else { return false }
            }
        }
        return true
    }
}
