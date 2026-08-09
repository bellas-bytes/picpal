import Foundation

/// An opaque timing token representing the start of a frame measurement.
///
/// Create via `FrameTimer.start()`. Pass back to `FrameTimer.stop(token:)` to record
/// the elapsed time. The start instant is captured synchronously at creation time.
public struct FrameTimerToken: Sendable {
    let startTime: ContinuousClock.Instant

    init() {
        startTime = .now
    }
}

/// An immutable snapshot of accumulated frame-timing statistics.
public struct FrameTimerStatistics: Sendable, Equatable, Encodable {

    /// Mean frame processing time in milliseconds.
    public let meanMs: Double

    /// 95th-percentile frame processing time in milliseconds.
    public let p95Ms: Double

    /// Maximum observed frame processing time in milliseconds.
    public let maxMs: Double

    /// Number of frames that exceeded `FrameTimer.frameTimeBudgetMs`.
    public let dropCount: Int

    /// A baseline zero-value statistic used before any samples are recorded.
    public static let zero = FrameTimerStatistics(meanMs: 0, p95Ms: 0, maxMs: 0, dropCount: 0)
}

/// Measures per-frame processing time and tracks budget violations.
///
/// ## Thread-safety
/// `FrameTimer` is an actor. `start()` is `nonisolated` — it captures only the current
/// clock instant and touches no shared state. `stop(token:)` is actor-isolated and may
/// be dispatched asynchronously from a synchronous frame callback:
///
/// ```swift
/// let token = frameTimer.start()                  // synchronous — captures time now
/// processFrame()
/// Task { await frameTimer.stop(token: token) }    // async — elapsed computed from token
/// ```
///
/// The elapsed time is computed from the token's captured `startTime`, not from when the
/// Task executes, so scheduling latency does not inflate the measurement.
public actor FrameTimer {

    // MARK: - Constants

    /// Per-frame time budget in milliseconds (60 fps target = 16.67 ms/frame).
    public static let frameTimeBudgetMs: Double = 16.67

    /// Maximum number of timing samples retained for rolling statistics (~5 s at 60 fps).
    private static let maxSamples: Int = 300

    // MARK: - State

    private var samples: [Double] = []
    private var dropCount: Int = 0

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// Begin timing a frame. Captures the current clock instant synchronously.
    ///
    /// `nonisolated` — accesses no actor-isolated state. Call from any thread or isolation
    /// context without `await`.
    public nonisolated func start() -> FrameTimerToken {
        FrameTimerToken()
    }

    /// Record elapsed time for the given token. Increments the drop counter if the elapsed
    /// time exceeded `frameTimeBudgetMs`.
    public func stop(token: FrameTimerToken) {
        let elapsed = ContinuousClock.now - token.startTime
        let ms = milliseconds(from: elapsed)
        appendSample(ms)
    }

    /// A point-in-time snapshot of accumulated timing statistics.
    public var statistics: FrameTimerStatistics {
        guard !samples.isEmpty else { return .zero }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let maxVal = samples.max() ?? 0
        let p95 = percentile(0.95, in: samples)
        return FrameTimerStatistics(meanMs: mean, p95Ms: p95, maxMs: maxVal, dropCount: dropCount)
    }

    // MARK: - Internal — accessible via @testable import

    /// Injects a synthetic elapsed-time sample, bypassing the real clock.
    ///
    /// For unit tests only — allows verifying statistics logic without waiting for actual
    /// clock ticks.
    func injectSample(ms: Double) {
        appendSample(ms)
    }

    // MARK: - Private helpers

    private func appendSample(_ ms: Double) {
        if samples.count >= Self.maxSamples {
            samples.removeFirst()
        }
        samples.append(ms)
        if ms > Self.frameTimeBudgetMs {
            dropCount += 1
        }
    }

    private func percentile(_ p: Double, in values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Swift.max(0, Int(ceil(p * Double(sorted.count))) - 1)
        return sorted[Swift.min(index, sorted.count - 1)]
    }

    /// Convert a `Duration` to milliseconds.
    ///
    /// `Duration.components` gives `(seconds: Int64, attoseconds: Int64)`.
    /// One millisecond equals 1 × 10¹⁵ attoseconds.
    private func milliseconds(from duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000
             + Double(attoseconds) / 1_000_000_000_000_000
    }
}
