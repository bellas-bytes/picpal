import Foundation

/// The complete session payload serialised to disk.
public struct TelemetrySnapshot: Sendable, Encodable {
    /// Accumulated frame-timing statistics for the session.
    public let frameStats: FrameTimerStatistics
    /// Ordered list of thermal state transitions observed during the session.
    public let thermalEvents: [ThermalEvent]
    /// Battery drain report, `nil` if battery monitoring was not started.
    public let batteryReport: BatteryReport?
    /// Cue KPI summary for the session, `nil` if the cue logger was not active.
    public let cueTelemetry: CueTelemetryReport?
    /// Post-session Likert rating (1–5), `nil` until M4-4 survey is implemented.
    public let surveyResponse: Int?

    public init(
        frameStats: FrameTimerStatistics,
        thermalEvents: [ThermalEvent],
        batteryReport: BatteryReport? = nil,
        cueTelemetry: CueTelemetryReport? = nil,
        surveyResponse: Int? = nil
    ) {
        self.frameStats = frameStats
        self.thermalEvents = thermalEvents
        self.batteryReport = batteryReport
        self.cueTelemetry = cueTelemetry
        self.surveyResponse = surveyResponse
    }
}

/// Errors thrown by `TelemetryExporter`.
public enum TelemetryExportError: Error, Equatable {
    /// The app's Documents directory could not be located.
    case documentsDirectoryUnavailable
}

/// Writes a session summary to disk as a timestamped, pretty-printed JSON file.
///
/// ## Filename format
/// `picpal-telemetry-<ISO8601-timestamp>.json`
/// Colons are replaced with hyphens for filesystem compatibility.
///
/// ## Usage
/// ```swift
/// let exporter = try TelemetryExporter.inDocuments()
/// let url = try exporter.export(snapshot: snapshot)
/// print("Wrote telemetry to \(url.lastPathComponent)")
/// ```
public struct TelemetryExporter {

    // MARK: - Constants

    private enum FilenameConstants {
        static let prefix = "picpal-telemetry-"
        static let ext    = ".json"
    }

    // MARK: - Dependencies

    /// The directory into which JSON files are written.
    let outputDirectory: URL

    // MARK: - Init

    /// Creates an exporter that writes to `outputDirectory`.
    public init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    /// Creates an exporter targeting the app's Documents directory.
    ///
    /// - Throws: `TelemetryExportError.documentsDirectoryUnavailable`
    public static func inDocuments() throws -> TelemetryExporter {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw TelemetryExportError.documentsDirectoryUnavailable
        }
        return TelemetryExporter(outputDirectory: url)
    }

    // MARK: - Export

    /// Encode `snapshot` as JSON and write it atomically to the output directory.
    ///
    /// - Returns: The `URL` of the written file.
    @discardableResult
    public func export(snapshot: TelemetrySnapshot) throws -> URL {
        let encoder = makeEncoder()
        let data = try encoder.encode(snapshot)
        let fileURL = outputDirectory.appendingPathComponent(makeFilename())
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    // MARK: - Private

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeFilename() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
        let timestamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return FilenameConstants.prefix + timestamp + FilenameConstants.ext
    }
}
