import os

/// Lock-protected per-session call counter for the VLM tier.
///
/// Once exhausted, `tryConsume()` permanently returns `false` for the session.
/// Budget depletion is reported distinctly from a network failure — a depleted
/// budget is a cost-control gate, not an error condition.
///
/// ## Thread safety
/// All mutable state is guarded by `OSAllocatedUnfairLock`. Safe to call from
/// any thread or isolation context.
public final class VLMSessionBudget: @unchecked Sendable {

    // MARK: - Named constant

    /// Default maximum number of VLM calls per app session.
    /// Changing this value is a one-line edit — no other callsites need updating.
    public static let defaultMaxCallsPerSession: Int = 50

    // MARK: - Private state

    private struct BudgetState {
        var callsUsed: Int
        var isExhausted: Bool

        /// Initial state. Sets `isExhausted` immediately when `max` ≤ 0 so
        /// `tryConsume` returns `false` without touching the counter.
        static func initial(max: Int) -> BudgetState {
            BudgetState(callsUsed: 0, isExhausted: max <= 0)
        }
    }

    private let lock: OSAllocatedUnfairLock<BudgetState>
    private let maxCalls: Int

    // MARK: - Init

    /// Creates a budget with the given session cap.
    ///
    /// - Parameter maxCalls: Maximum VLM calls for this session.
    ///   Defaults to `defaultMaxCallsPerSession`. Pass `0` to create a
    ///   pre-exhausted budget (useful for offline mode).
    public init(maxCalls: Int = VLMSessionBudget.defaultMaxCallsPerSession) {
        self.maxCalls = maxCalls
        self.lock = OSAllocatedUnfairLock(initialState: .initial(max: maxCalls))
    }

    // MARK: - Public API

    /// Attempt to consume one unit from the session budget.
    ///
    /// - Returns: `true` if a budget unit was available and has been consumed.
    ///   `false` when the budget is already exhausted — exhaustion is sticky and
    ///   permanent for the session.
    @discardableResult
    public func tryConsume() -> Bool {
        lock.withLock { state in
            guard !state.isExhausted else { return false }
            state.callsUsed += 1
            if state.callsUsed >= maxCalls {
                state.isExhausted = true
            }
            return true
        }
    }

    /// `true` when the session budget is fully consumed.
    ///
    /// Once `true`, `tryConsume()` will always return `false`.
    public var isExhausted: Bool {
        lock.withLock { $0.isExhausted }
    }

    /// Number of VLM calls remaining in this session.
    ///
    /// Saturates at `0` — never goes negative.
    public var callsRemaining: Int {
        lock.withLock { max(0, maxCalls - $0.callsUsed) }
    }
}
