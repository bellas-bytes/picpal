import Foundation
import os

/// Thread-safe ring-buffer log of `CueEvent` records, with a `makeSummary()` method
/// that computes KPI aggregates for the current session.
///
/// `CueLogger` is safe to call from any thread — all state is protected by
/// `OSAllocatedUnfairLock`.
///
/// ## Ring-buffer behaviour
/// When the log reaches `maxEventCount` entries, the oldest event is dropped before
/// the new one is appended — keeping memory bounded over long sessions.
public final class CueLogger: @unchecked Sendable {

    // MARK: - Constants

    /// Maximum number of events retained in memory before the oldest is evicted.
    public static let maxEventCount: Int = 500

    // MARK: - State

    private let lock: OSAllocatedUnfairLock<[CueEvent]>
    private let sessionStart: Date

    // MARK: - Init

    /// Creates a `CueLogger`.
    ///
    /// - Parameter sessionStart: The logical start time for session-duration calculations.
    ///   Defaults to `Date()` (the moment the logger is created).
    public init(sessionStart: Date = Date()) {
        self.lock = OSAllocatedUnfairLock(initialState: [])
        self.sessionStart = sessionStart
    }

    // MARK: - Recording

    /// Append `event` to the log, evicting the oldest entry if the buffer is full.
    public func record(_ event: CueEvent) {
        lock.withLock { events in
            if events.count >= Self.maxEventCount {
                events.removeFirst()   // ring-buffer: drop oldest
            }
            events.append(event)
        }
    }

    // MARK: - Retrieval

    /// Returns a snapshot of all currently retained events in chronological order.
    public func events() -> [CueEvent] {
        lock.withLock { $0 }
    }

    // MARK: - Aggregation

    /// Computes and returns a `CueTelemetryReport` from the current event snapshot.
    ///
    /// Percentile calculations use the nearest-rank method on the sorted latency array.
    /// `p95SettleLatencyMs` is `nil` until at least `CueTelemetryReport.minSamplesForPercentile`
    /// latency samples exist.
    public func makeSummary() -> CueTelemetryReport {
        let snapshot = lock.withLock { $0 }

        let total = snapshot.count
        let t0  = snapshot.filter { $0.tier == .tier0  }.count
        let t05 = snapshot.filter { $0.tier == .tier05 }.count
        let t2  = snapshot.filter { $0.tier == .tier2  }.count

        let latencies = snapshot.compactMap { $0.latencyFromSettleMs }.sorted()
        let median: Double? = latencies.isEmpty ? nil : percentile(latencies, 0.5)
        let p95: Double? = latencies.count < CueTelemetryReport.minSamplesForPercentile
            ? nil
            : percentile(latencies, 0.95)

        let duration = Date().timeIntervalSince(sessionStart)
        return CueTelemetryReport(
            totalCues: total,
            tier0Count: t0,
            tier05Count: t05,
            tier2Count: t2,
            medianSettleLatencyMs: median,
            p95SettleLatencyMs: p95,
            sessionDurationSeconds: duration
        )
    }

    // MARK: - Private helpers

    /// Nearest-rank percentile on a pre-sorted array.
    ///
    /// - Parameters:
    ///   - sorted: A non-empty, ascending-sorted array of doubles.
    ///   - p: Percentile in [0, 1].
    /// - Returns: The value at the nearest-rank position.
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)
        return sorted[min(idx, sorted.count - 1)]
    }
}
