import Foundation
import os

// MARK: - PredictiveCoach

/// Tracks whether a corrective signal is actively improving and gates cue emission accordingly.
///
/// The coach runs a simple state machine per signal:
/// - **idle**: no active improvement session.
/// - **waiting(since:)**: improvement detected; waiting to see if threshold is reached.
///
/// On each call to `update(trend:isWithinThreshold:)` the coach transitions state and
/// returns an `Action` that tells `CueEvaluator` whether to emit a predictive hint,
/// a positive confirmation, a corrective cue, or silence.
///
/// ## Thread safety
/// All state transitions are protected by `OSAllocatedUnfairLock`. `update` and `reset`
/// may be called concurrently from any thread.
final class PredictiveCoach: @unchecked Sendable {

    // MARK: - Constants

    /// Default wait window (seconds) before reverting to corrective if threshold not met.
    static let defaultWaitWindowSeconds: Double = 2.5

    // MARK: - State

    enum State: Equatable, Sendable {
        case idle
        case waiting(since: Date)
    }

    // MARK: - Action

    /// The action `CueEvaluator` should take for this signal this frame.
    enum Action: Sendable, Equatable {
        /// Emit a predictive hint ("almost level" etc.).
        case emitPredictiveHint
        /// Emit a positive confirmation cue — signal crossed threshold while waiting.
        case emitPositiveCue
        /// Revert to the normal corrective cue for this signal.
        case revertToCorrective
        /// Suppress the corrective cue but continue evaluating lower-priority cues.
        case silent
        /// Take no predictive action — signal is fine or coach is idle.
        case idle
    }

    // MARK: - Private properties

    private let lock: OSAllocatedUnfairLock<State>
    private let waitWindowSeconds: Double
    private let clock: @Sendable () -> Date

    // MARK: - Init

    init(
        waitWindowSeconds: Double = defaultWaitWindowSeconds,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lock = OSAllocatedUnfairLock(initialState: .idle)
        self.waitWindowSeconds = waitWindowSeconds
        self.clock = clock
    }

    // MARK: - Update

    /// Called each frame with the current trend and whether the signal is in the good zone.
    ///
    /// - Parameters:
    ///   - trend: The current `SignalTrendDetector.Trend` for this signal.
    ///   - isWithinThreshold: `true` when the signal is already inside the good zone.
    /// - Returns: The `Action` `CueEvaluator` should take for this signal.
    func update(trend: SignalTrendDetector.Trend, isWithinThreshold: Bool) -> Action {
        lock.withLock { state in
            let now = clock()
            switch (trend, isWithinThreshold, state) {

            // Threshold crossed while we were waiting — positive confirmation.
            case (_, true, .waiting):
                state = .idle
                return .emitPositiveCue

            // Threshold already met from idle — nothing to coach.
            case (_, true, _):
                state = .idle
                return .idle

            // First improving frame from idle — start the wait window and emit hint.
            case (.improving, false, .idle):
                state = .waiting(since: now)
                return .emitPredictiveHint

            // Improving but still waiting — check if window has elapsed.
            case (.improving, false, .waiting(let since)):
                if now.timeIntervalSince(since) >= waitWindowSeconds {
                    state = .idle
                    return .revertToCorrective
                }
                return .silent

            // Worsening, or stable while waiting — abandon the session.
            case (.worsening, _, _), (.stable, false, .waiting):
                state = .idle
                return .revertToCorrective

            // Any other combination (e.g. stable + idle) — stay idle.
            default:
                return .idle
            }
        }
    }

    // MARK: - Reset

    /// Clears state. Call on scene change or session end.
    func reset() {
        lock.withLock { $0 = .idle }
    }
}

// MARK: - PredictiveActions

/// Snapshot of predictive coach actions for one frame evaluation.
///
/// Created once per frame from the per-signal coaches and passed into `CueEvaluator.evaluate`.
/// Using a value-type snapshot keeps `CueEvaluator` a pure, stateless function.
struct PredictiveActions: Sendable {
    var tilt: PredictiveCoach.Action = .idle
    var exposure: PredictiveCoach.Action = .idle

    /// Convenience constant: no predictive intervention on any signal.
    static let noAction = PredictiveActions()
}
