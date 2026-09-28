import Foundation

/// Strict schema validation; model prose and fenced/truncated JSON are never accepted.
enum ReferenceAnalysisParser {
    enum ValidationError: Error { case invalidSchema }
    static func text(_ value: String, limit: Int) throws {
        guard value.count <= limit else { throw ValidationError.invalidSchema }
    }
    static func confidence(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw ValidationError.invalidSchema }
    }
    static func dimensions(_ values: [ReferenceDimension]) throws {
        guard values.count == 5, Set(values) == Set(ReferenceDimension.allCases) else {
            throw ValidationError.invalidSchema
        }
    }
    static func parseProfile(_ data: Data) throws -> ReferenceProfile {
        let profile = try JSONDecoder().decode(ReferenceProfile.self, from: data)
        guard profile.schemaVersion == 1 else { throw ValidationError.invalidSchema }
        try text(profile.summary, limit: 240)
        try dimensions(profile.features.map(\.dimension))
        for feature in profile.features {
            try text(feature.evidence, limit: 240)
            try confidence(feature.confidence)
        }
        return profile
    }
    static func parseComparison(_ data: Data) throws -> ReferenceComparison {
        let comparison = try JSONDecoder().decode(ReferenceComparison.self, from: data)
        guard comparison.schemaVersion == 1 else { throw ValidationError.invalidSchema }
        try dimensions(comparison.dimensions.map(\.dimension))
        for dimension in comparison.dimensions {
            try text(dimension.referenceEvidence, limit: 240)
            try text(dimension.liveEvidence, limit: 240)
            try confidence(dimension.confidence)
        }
        if let action = comparison.action {
            guard comparison.dimensions.first(where: { $0.dimension == action.dimension })?.status == .different,
                  !action.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !action.direction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.invalidSchema
            }
            try text(action.id, limit: 80)
            try text(action.direction, limit: 80)
            try text(action.instruction, limit: 120)
            try text(action.expectedChange, limit: 240)
            try confidence(action.confidence)
        }
        return comparison
    }
}
