import os

// MARK: - Private state

private struct SmootherState<T> {
    var runValue: T?
    var runCount: Int
    var isStableConfirmed: Bool

    init() {
        runValue = nil
        runCount = 0
        isStableConfirmed = false
    }
}

/// Conditional `Sendable` conformance: all stored properties are `Sendable`
/// when `T` is `Sendable`, satisfying `OSAllocatedUnfairLock`'s `State` constraint.
extension SmootherState: Sendable where T: Sendable {}

// MARK: - TemporalSmoother

/// Thread-safe rolling-window accumulator that emits a stable signal only after
/// a value has appeared in `stableFrameCount` consecutive frames (edge-triggered).
///
/// ## Edge-triggered contract
/// - `onStable(value)` fires **exactly once** when a run of equal non-nil values
///   reaches `stableFrameCount`. Subsequent frames with the same value do not
///   re-fire the callback.
/// - When the value changes or `update(nil)` is called and stability was previously
///   confirmed, `onStable(nil)` fires **exactly once** and the cycle resets.
/// - When stability has not yet been confirmed, a value change or nil update clears
///   the run silently (no callback).
///
/// ## Thread safety
/// All mutable state is protected by `OSAllocatedUnfairLock`. The `onStable`
/// callback is invoked on the calling thread after the lock is released.
public final class TemporalSmoother<T: Sendable & Equatable>: @unchecked Sendable {

    // MARK: - Constants

    /// Default consecutive-frame count required to confirm stability.
    public static var defaultStableFrameCount: Int { 3 }

    // MARK: - State

    private let lock: OSAllocatedUnfairLock<SmootherState<T>>
    private let stableFrameCount: Int
    private let onStable: @Sendable (T?) -> Void

    // MARK: - Init

    /// Creates a `TemporalSmoother`.
    ///
    /// - Parameters:
    ///   - stableFrameCount: Consecutive equal frames required before `onStable`
    ///     fires. Defaults to `defaultStableFrameCount`.
    ///   - onStable: Called on the calling thread when stability is confirmed or
    ///     broken. Receives the stable value on confirmation; `nil` on break.
    public init(
        stableFrameCount: Int = TemporalSmoother.defaultStableFrameCount,
        onStable: @escaping @Sendable (T?) -> Void
    ) {
        self.stableFrameCount = stableFrameCount
        self.onStable = onStable
        self.lock = OSAllocatedUnfairLock(initialState: SmootherState())
    }

    // MARK: - Public API

    /// Feed a new observed value.
    ///
    /// - Parameter value: The current observation. Pass `nil` when the keypoint
    ///   is absent or was rejected by `KeypointFilter`.
    public func update(_ value: T?) {
        let (shouldCallback, callbackArg): (Bool, T?) = lock.withLock { state in
            computeUpdate(state: &state, value: value)
        }
        if shouldCallback {
            onStable(callbackArg)
        }
    }

    /// Reset accumulated state without firing any callback.
    ///
    /// Call when the scene changes or the pipeline restarts to prevent stale
    /// run counts from producing a false-stable signal.
    public func reset() {
        lock.withLock { state in
            state.runValue = nil
            state.runCount = 0
            state.isStableConfirmed = false
        }
    }

    // MARK: - Private helpers

    /// Pure decision function — all state transitions happen here.
    ///
    /// Returns `(shouldCallback, callbackArg)`:
    /// - `(true, someValue)` → call `onStable(someValue)` (stable confirmed)
    /// - `(true, nil)`      → call `onStable(nil)`      (stability broken)
    /// - `(false, nil)`     → no callback
    private func computeUpdate(
        state: inout SmootherState<T>,
        value: T?
    ) -> (Bool, T?) {
        guard let value else {
            // nil: break any current run.
            let wasStable = state.isStableConfirmed
            state.runValue = nil
            state.runCount = 0
            state.isStableConfirmed = false
            return (wasStable, nil)
        }

        // Check if this continues the current run.
        if let current = state.runValue, current == value {
            // Edge-triggered: do not re-fire once stable.
            guard !state.isStableConfirmed else { return (false, nil) }
            state.runCount += 1
            if state.runCount >= stableFrameCount {
                state.isStableConfirmed = true
                return (true, value)
            }
            return (false, nil)
        }

        // New value (or first observation after reset): restart the run.
        let wasStable = state.isStableConfirmed
        state.runValue = value
        state.runCount = 1
        state.isStableConfirmed = false
        // If a stable value was previously confirmed, breaking it fires nil.
        return (wasStable, nil)
    }
}
