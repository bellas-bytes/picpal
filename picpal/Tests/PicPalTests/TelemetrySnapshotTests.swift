import Testing
import Foundation
@testable import PicPal

@Suite("TelemetrySnapshot — new optional fields")
struct TelemetrySnapshotTests {

    // MARK: - Helpers

    private static let emptyStats = FrameTimerStatistics(meanMs: 0, p95Ms: 0, maxMs: 0, dropCount: 0)

    private static let sampleCueTelemetry = CueTelemetryReport(
        totalCues: 10,
        tier0Count: 6,
        tier05Count: 3,
        tier2Count: 1,
        medianSettleLatencyMs: 250,
        p95SettleLatencyMs: 480,
        sessionDurationSeconds: 180
    )

    // MARK: - Tests

    @Test("snapshot_encodesWithNilOptionals: JSON omits cueTelemetry and surveyResponse keys")
    func snapshot_encodesWithNilOptionals() throws {
        let snapshot = TelemetrySnapshot(
            frameStats: Self.emptyStats,
            thermalEvents: []
        )
        #expect(snapshot.batteryReport == nil)
        #expect(snapshot.cueTelemetry == nil)
        #expect(snapshot.surveyResponse == nil)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // JSONEncoder omits nil Optional values by default — keys must not appear.
        #expect(json != nil)
        #expect(json?.keys.contains("cueTelemetry") == false)
        #expect(json?.keys.contains("surveyResponse") == false)
    }

    @Test("snapshot_encodesWithAllFields: surveyResponse appears in JSON")
    func snapshot_encodesWithAllFields() throws {
        let snapshot = TelemetrySnapshot(
            frameStats: Self.emptyStats,
            thermalEvents: [],
            batteryReport: nil,
            cueTelemetry: Self.sampleCueTelemetry,
            surveyResponse: 3
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let jsonString = String(decoding: data, as: UTF8.self)

        #expect(jsonString.contains("\"surveyResponse\" : 3"))
        #expect(jsonString.contains("\"totalCues\" : 10"))
    }

    @Test("snapshot_existingThreeArgInitStillCompiles: three-argument init leaves new fields nil")
    func snapshot_existingThreeArgInitStillCompiles() {
        let snapshot = TelemetrySnapshot(
            frameStats: Self.emptyStats,
            thermalEvents: [],
            batteryReport: nil
        )
        #expect(snapshot.cueTelemetry == nil)
        #expect(snapshot.surveyResponse == nil)
    }
}
