import Foundation
import os

/// Tracks whether Tier-0 signals are actively improving toward their thresholds.
/// Only tilt and exposure are tracked — blur/shake have no reliable trend.
final class SignalTrendDetector: @unchecked Sendable {

    enum TrackedSignal: Hashable { case tilt, exposure }

    enum Trend: Equatable {
        case improving   // slope exceeds threshold and signal is outside the good zone
        case stable      // little or no directional change
        case worsening   // moving away from threshold
    }

    struct Sample: Sendable {
        let value: Double
        let timestamp: Date
    }

    static let defaultWindowSeconds: Double = 1.5
    static let defaultImprovementSlopeThreshold: Double = 0.03  // units/second

    private let lock: OSAllocatedUnfairLock<[TrackedSignal: [Sample]]>
    private let windowSeconds: Double
    private let improvementSlopeThreshold: Double
    private let clock: @Sendable () -> Date

    init(
        windowSeconds: Double = defaultWindowSeconds,
        improvementSlopeThreshold: Double = defaultImprovementSlopeThreshold,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lock = OSAllocatedUnfairLock(initialState: [:])
        self.windowSeconds = windowSeconds
        self.improvementSlopeThreshold = improvementSlopeThreshold
        self.clock = clock
    }

    /// Called each frame with the current raw signal value.
    /// For tilt: value = abs(tiltAngleRadians). Improvement = decreasing value.
    /// For exposure: value = abs(exposureDeviation). Improvement = decreasing value.
    func record(signal: TrackedSignal, value: Double) {
        let now = clock()
        lock.withLock { samples in
            var s = samples[signal, default: []]
            s.append(Sample(value: value, timestamp: now))
            // Trim to window
            s = s.filter { now.timeIntervalSince($0.timestamp) <= windowSeconds }
            samples[signal] = s
        }
    }

    /// Returns the current trend for a signal.
    func trend(for signal: TrackedSignal) -> Trend {
        let samples = lock.withLock { $0[signal, default: []] }
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else { return .stable }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return .stable }
        let slope = (last.value - first.value) / duration
        // Negative slope = decreasing = improving (both tilt and exposure use abs values)
        if slope < -improvementSlopeThreshold { return .improving }
        if slope > improvementSlopeThreshold { return .worsening }
        return .stable
    }

    /// Clears all samples. Call on scene change.
    func reset() {
        lock.withLock { $0.removeAll() }
    }
}
