import Foundation
import os

/// Tracks the most recent "settled" event timestamp so that settle→cue latency can be
/// computed at the moment a cue is emitted.
///
/// `SettleEventTimer` is safe to call from any thread — all state is protected by
/// `OSAllocatedUnfairLock`.
///
/// ## Usage
/// ```swift
/// // When the scene settles:
/// settleTimer.recordSettle()
///
/// // When a cue fires:
/// let latencyMs = settleTimer.latencyMilliseconds(cueAt: Date())
/// settleTimer.reset()   // clear so the next burst starts fresh
/// ```
public final class SettleEventTimer: @unchecked Sendable {

    // MARK: - State

    private let lock: OSAllocatedUnfairLock<Date?>
    private let clock: @Sendable () -> Date

    // MARK: - Init

    /// Creates a `SettleEventTimer`.
    ///
    /// - Parameter clock: Injectable time source — defaults to `{ Date() }`. Override in
    ///   tests to control time precisely without real delays.
    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.lock = OSAllocatedUnfairLock(initialState: nil)
        self.clock = clock
    }

    // MARK: - API

    /// Record a settle event at the current clock time.
    public func recordSettle() {
        lock.withLock { $0 = clock() }
    }

    /// Returns milliseconds elapsed between the last settle event and `cueAt`.
    ///
    /// Returns `nil` when:
    /// - No settle has been recorded yet.
    /// - `cueAt` is before the settle time (prevents negative latency).
    public func latencyMilliseconds(cueAt: Date) -> Double? {
        guard let settleTime = lock.withLock({ $0 }) else { return nil }
        let delta = cueAt.timeIntervalSince(settleTime) * 1000
        return delta >= 0 ? delta : nil
    }

    /// Clear the settle timestamp (call on scene change or after first cue in a burst).
    public func reset() {
        lock.withLock { $0 = nil }
    }
}
