import Testing
import Foundation
@testable import PicPal

@Suite("TelemetryExporter")
struct TelemetryExporterTests {

    // MARK: - Helpers

    private func makeSnapshot(
        frameStats: FrameTimerStatistics = .zero,
        thermalEvents: [ThermalEvent] = [],
        batteryReport: BatteryReport? = nil
    ) -> TelemetrySnapshot {
        TelemetrySnapshot(
            frameStats: frameStats,
            thermalEvents: thermalEvents,
            batteryReport: batteryReport
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - TelemetrySnapshot

    @Test("TelemetrySnapshot stores frameStats correctly")
    func snapshotStoresFrameStats() {
        let stats = FrameTimerStatistics(meanMs: 5, p95Ms: 10, maxMs: 20, dropCount: 1)
        let snapshot = makeSnapshot(frameStats: stats)
        #expect(snapshot.frameStats == stats)
    }

    @Test("TelemetrySnapshot batteryReport defaults to nil")
    func snapshotBatteryReportDefaultsToNil() {
        let snapshot = makeSnapshot()
        #expect(snapshot.batteryReport == nil)
    }

    @Test("TelemetrySnapshot stores batteryReport when supplied")
    func snapshotStoresBatteryReport() {
        let report = BatteryReport(startLevel: 0.9, endLevel: 0.8, duration: 60)
        let snapshot = makeSnapshot(batteryReport: report)
        #expect(snapshot.batteryReport == report)
    }

    // MARK: - TelemetryExporter (file system)

    @Test("export creates a file at the returned URL")
    func exportCreatesFile() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("exported filename has the picpal-telemetry- prefix")
    func filenamePrefixIsCorrect() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot())
        #expect(url.lastPathComponent.hasPrefix("picpal-telemetry-"))
    }

    @Test("exported filename has the .json extension")
    func filenameExtensionIsJSON() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot())
        #expect(url.pathExtension == "json")
    }

    @Test("exported filename contains no colons")
    func filenameContainsNoColons() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot())
        #expect(!url.lastPathComponent.contains(":"))
    }

    @Test("exported file is valid JSON")
    func exportedFileIsValidJSON() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot())
        let data = try Data(contentsOf: url)
        let json = try? JSONSerialization.jsonObject(with: data)
        #expect(json != nil)
    }

    @Test("exported JSON contains frameStats key")
    func exportedJSONContainsFrameStats() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot())
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["frameStats"] != nil)
    }

    @Test("exported JSON contains thermalEvents key")
    func exportedJSONContainsThermalEvents() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot())
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["thermalEvents"] != nil)
    }

    @Test("exported JSON omits batteryReport key when not provided")
    func exportedJSONBatteryReportOmittedWhenNil() throws {
        let dir = try makeTempDirectory()
        let exporter = TelemetryExporter(outputDirectory: dir)
        let url = try exporter.export(snapshot: makeSnapshot(batteryReport: nil))
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // JSONEncoder omits nil Optional values by default (no key written)
        #expect(json?.keys.contains("batteryReport") == false)
    }

    // MARK: - inDocuments factory

    @Test("inDocuments returns an exporter (no throw in app context)")
    func inDocumentsFactoryDoesNotThrow() {
        // On simulator / test host the Documents directory is available
        #expect(throws: Never.self) {
            _ = try TelemetryExporter.inDocuments()
        }
    }
}
