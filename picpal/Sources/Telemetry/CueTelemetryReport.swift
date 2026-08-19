import Foundation

/// Aggregated KPI summary produced by `CueLogger.makeSummary()`.
///
/// Covers the primary M4 success metrics:
/// - Cue-count totals and per-tier breakdown
/// - Settle→cue latency distribution (median, p95)
/// - Session duration for normalising rates
public struct CueTelemetryReport: Sendable, Encodable, Equatable {
    /// Total number of cue events recorded this session.
    public let totalCues: Int

    /// Number of Tier-0 (on-device CV) cues.
    public let tier0Count: Int

    /// Number of Tier-0.5 (Vision landmarks) cues.
    public let tier05Count: Int

    /// Number of Tier-2 (cloud VLM) cues.
    public let tier2Count: Int

    /// Median settle→cue latency in milliseconds across all events that have a latency sample.
    /// `nil` when no latency samples exist.
    public let medianSettleLatencyMs: Double?

    /// 95th-percentile settle→cue latency in milliseconds.
    /// `nil` when fewer than `minSamplesForPercentile` latency samples exist.
    public let p95SettleLatencyMs: Double?

    /// Total wall-clock duration of this session (seconds), measured from `CueLogger.sessionStart`.
    public let sessionDurationSeconds: TimeInterval

    /// Minimum number of latency samples required before p95 is computed.
    public static let minSamplesForPercentile: Int = 5
}
