import Foundation
import Testing
@testable import PicPal

struct ReferenceAnalysisParserTests {
    private func profile() -> [String: Any] {
        ["schemaVersion": 1, "summary": "Portrait", "features": ReferenceDimension.allCases.map {
            ["dimension": $0.rawValue, "evidence": "Visible", "confidence": 0.8, "applicable": true] as [String: Any]
        }]
    }
    private func comparison() -> [String: Any] {
        ["schemaVersion": 1, "dimensions": ReferenceDimension.allCases.map {
            ["dimension": $0.rawValue, "status": $0 == .pose ? "different" : "matched",
             "referenceEvidence": "Visible", "liveEvidence": "Visible", "confidence": 0.8] as [String: Any]
        }, "action": ["id": "arm", "dimension": "pose", "actor": "subject", "direction": "raise-left-arm",
                      "instruction": "Raise your left arm", "expectedChange": "Arm approaches reference", "confidence": 0.8]]
    }
    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    @Test func completeProfileAndComparisonDecode() throws {
        let p = try ReferenceAnalysisParser.parseProfile(data(profile()))
        let c = try ReferenceAnalysisParser.parseComparison(data(comparison()))
        #expect(p.features.count == 5)
        #expect(p.summary == "Portrait")
        #expect(c.dimensions.count == 5)
        #expect(c.action?.actor == .subject)
        #expect(c.action?.dimension == .pose)
        #expect(c.dimensions.first { $0.dimension == .pose }?.status == .different)
    }
    @Test(arguments: ["missing", "duplicate", "enum", "version", "confidence-low", "confidence-high", "evidence", "summary", "applicable"])
    func malformedProfilesAreRejected(mutation: String) throws {
        var value = profile()
        var features = value["features"] as! [[String: Any]]
        switch mutation {
        case "missing": features.removeLast()
        case "duplicate": features[1]["dimension"] = features[0]["dimension"]
        case "enum": features[0]["dimension"] = "emotion"
        case "version": value["schemaVersion"] = 2
        case "confidence-low": features[0]["confidence"] = -0.01
        case "confidence-high": features[0]["confidence"] = 1.01
        case "evidence": features[0]["evidence"] = String(repeating: "x", count: 241)
        case "summary": value["summary"] = String(repeating: "x", count: 241)
        default: features[0]["applicable"] = "true"
        }
        value["features"] = features
        let encoded = try data(value)
        #expect(throws: (any Error).self) { try ReferenceAnalysisParser.parseProfile(encoded) }
    }
    @Test(arguments: ["missing", "duplicate", "dimension-enum", "status-enum", "actor-enum", "version", "confidence-low", "confidence-high", "reference-evidence", "live-evidence", "action-confidence", "id", "direction", "instruction", "expected-change", "empty-instruction", "empty-direction", "unknown-action", "matched-action", "not-applicable-action"])
    func malformedComparisonsAreRejected(mutation: String) throws {
        var value = comparison()
        var dimensions = value["dimensions"] as! [[String: Any]]
        var action = value["action"] as! [String: Any]
        switch mutation {
        case "missing": dimensions.removeLast()
        case "duplicate": dimensions[1]["dimension"] = dimensions[0]["dimension"]
        case "dimension-enum": dimensions[0]["dimension"] = "emotion"
        case "status-enum": dimensions[0]["status"] = "probably"
        case "actor-enum": action["actor"] = "camera"
        case "version": value["schemaVersion"] = 0
        case "confidence-low": dimensions[0]["confidence"] = -0.01
        case "confidence-high": dimensions[0]["confidence"] = 1.01
        case "reference-evidence": dimensions[0]["referenceEvidence"] = String(repeating: "x", count: 241)
        case "live-evidence": dimensions[0]["liveEvidence"] = String(repeating: "x", count: 241)
        case "action-confidence": action["confidence"] = 1.01
        case "id": action["id"] = String(repeating: "x", count: 81)
        case "direction": action["direction"] = String(repeating: "x", count: 81)
        case "instruction": action["instruction"] = String(repeating: "x", count: 121)
        case "expected-change": action["expectedChange"] = String(repeating: "x", count: 241)
        case "empty-instruction": action["instruction"] = " \n "
        case "empty-direction": action["direction"] = " "
        case "unknown-action": dimensions[1]["status"] = "unknown"
        case "matched-action": dimensions[1]["status"] = "matched"
        default: dimensions[1]["status"] = "notApplicable"
        }
        value["dimensions"] = dimensions
        value["action"] = action
        let encoded = try data(value)
        #expect(throws: (any Error).self) { try ReferenceAnalysisParser.parseComparison(encoded) }
    }
    @Test(arguments: ["NaN", "Infinity", "-Infinity", "1e999", "\"NaN\""])
    func nonfiniteConfidenceIsRejected(token: String) throws {
        let profileText = String(decoding: try data(profile()), as: UTF8.self)
            .replacingOccurrences(of: "0.8", with: token)
        let comparisonText = String(decoding: try data(comparison()), as: UTF8.self)
            .replacingOccurrences(of: "0.8", with: token)
        #expect(throws: (any Error).self) { try ReferenceAnalysisParser.parseProfile(Data(profileText.utf8)) }
        #expect(throws: (any Error).self) { try ReferenceAnalysisParser.parseComparison(Data(comparisonText.utf8)) }
    }
    @Test(arguments: ["{", "{}", "[]", "```json\n{}\n```", "This portrait matches."])
    func proseAndMalformedJSONAreRejected(text: String) {
        #expect(throws: (any Error).self) { try ReferenceAnalysisParser.parseProfile(Data(text.utf8)) }
        #expect(throws: (any Error).self) { try ReferenceAnalysisParser.parseComparison(Data(text.utf8)) }
    }
    @Test func unknownWithoutActionRemainsUnknown() throws {
        var value = comparison()
        var dimensions = value["dimensions"] as! [[String: Any]]
        dimensions[1]["status"] = "unknown"
        value["dimensions"] = dimensions
        value["action"] = NSNull()
        let parsed = try ReferenceAnalysisParser.parseComparison(data(value))
        #expect(parsed.action == nil)
        #expect(parsed.dimensions.first { $0.dimension == .pose }?.status == .unknown)
    }
}
