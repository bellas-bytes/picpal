import Foundation
import os

// MARK: - CueEvaluator

/// A pure, stateless evaluator that maps a `SignalFrame` to the single highest-priority cue.
///
/// `CueEvaluator` is a value type with no stored mutable state — safe to call from any
/// thread or queue. All debounce and hysteresis logic lives in `CueEngine`.
///
/// ## Priority chain (M1 signals)
/// 1. **Stability — tilt**: `tilt.isLevel == false`
/// 2. **Stability — blur**: `blur.isBlurry == true`
/// 3. **Exposure**: `exposure.level` is `.underexposed` or `.overexposed`
/// 4. **Composition**: `framing.hint` is a directional nudge or `.tooCentered`
///
/// Slots 5+ (body, aesthetic) are reserved for M2/M3 — add new cases above `return nil`.
public struct CueEvaluator: Sendable {

    public init() {}

    /// Evaluates `frame` and returns the single highest-priority cue, or `nil` if all
    /// signals are in a good state (or absent).
    ///
    /// ## Tie-break rule for co-equal stability cues
    /// Tilt and blur are both priority `.stability`. When the frame has both
    /// `tilt.isLevel == false` **and** `blur.isBlurry == true`, **tilt wins** — it
    /// appears first in the evaluation chain and is the more actionable correction.
    ///
    /// ## Edge case: `angleDegrees == 0.0` but `isLevel == false`
    /// This borderline state arises when the level dead-zone is computed without a
    /// sign. The evaluator defaults to `.tiltLeft` as a conservative fallback.
    public func evaluate(frame: SignalFrame) -> Cue? {

        // 0.5. Lens obstruction — checked before stability so it can bypass any
        //      lower-priority cooldown. Uses .obstruction priority (outranks stability).
        if let body = frame.body, body.hint == .lensObstructed {
            return Cue(text: CueText.lensObstructed, priority: .obstruction, sourceTier: .tier05)
        }

        // 1. Stability: tilt
        if let tilt = frame.tilt, !tilt.isLevel {
            let text = tilt.angleDegrees >= 0 ? CueText.tiltLeft : CueText.tiltRight
            return Cue(text: text, priority: .stability, sourceTier: .tier0)
        }

        // 2. Stability: blur
        if let blur = frame.blur, blur.isBlurry {
            return Cue(text: CueText.holdStill, priority: .stability, sourceTier: .tier0)
        }

        // 3. Exposure
        if let exposure = frame.exposure {
            switch exposure.level {
            case .underexposed:
                return Cue(text: CueText.tooDark, priority: .exposure, sourceTier: .tier0)
            case .overexposed:
                return Cue(text: CueText.tooLight, priority: .exposure, sourceTier: .tier0)
            case .ok:
                break
            }
        }

        // 4. Composition: framing
        if let framing = frame.framing {
            switch framing.hint {
            case .nudgeLeft:
                return Cue(text: CueText.nudgeLeft, priority: .composition, sourceTier: .tier0)
            case .nudgeRight:
                return Cue(text: CueText.nudgeRight, priority: .composition, sourceTier: .tier0)
            case .nudgeUp:
                return Cue(text: CueText.nudgeUp, priority: .composition, sourceTier: .tier0)
            case .nudgeDown:
                return Cue(text: CueText.nudgeDown, priority: .composition, sourceTier: .tier0)
            case .tooCentered:
                return Cue(text: CueText.tooCentered, priority: .composition, sourceTier: .tier0)
            case .goodFrame, .noSubject:
                break
            }
        }

        // 4.5. Body framing signals — awkward crop, gaze, and headroom.
        //      lensObstructed is handled at 0.5 above; goodBody means silence.
        if let body = frame.body {
            switch body.hint {
            case .awkwardCrop:
                return Cue(text: CueText.awkwardCrop, priority: .body, sourceTier: .tier05)
            case .gazeAway:
                return Cue(text: CueText.gazeAway, priority: .body, sourceTier: .tier05)
            case .nudgeDownHeadroom:
                return Cue(text: CueText.nudgeDownHeadroom, priority: .body, sourceTier: .tier05)
            case .nudgeUpHeadroom:
                return Cue(text: CueText.nudgeUpHeadroom, priority: .body, sourceTier: .tier05)
            case .lensObstructed, .goodBody:
                break  // lensObstructed handled above; goodBody = silence
            }
        }

        // All signals are in a good state (or absent) — emit silence.
        return nil
    }
}

// MARK: - CueEngine

/// Stateful cue engine that wraps `CueEvaluator` with debounce and repeat-suppression.
///
/// ## Thread safety
/// `process(frame:)` may be called from any thread or queue. All mutable state is
/// protected by `OSAllocatedUnfairLock`.
///
/// ## Debounce rules
/// - **Cadence cap**: after emitting any cue, all cues are suppressed for
///   `cueCooldownSeconds` to prevent rapid-fire coaching.
/// - **Repeat suppression**: the same cue text cannot fire again within
///   `minRepeatIntervalSeconds` (measured from the last emission of that text),
///   preventing the coach from nagging on a persistent issue.
public final class CueEngine: @unchecked Sendable {

    // MARK: - Named constants

    /// Default quiet period after every cue emission (seconds).
    public static let defaultCueCooldownSeconds: Double = 3.0

    /// Default minimum interval before the same cue text can repeat (seconds).
    public static let defaultMinRepeatIntervalSeconds: Double = 5.0

    // MARK: - Configuration (immutable after init)

    private let evaluator: CueEvaluator
    private let cueCooldownSeconds: Double
    private let minRepeatIntervalSeconds: Double
    private let clock: @Sendable () -> Date

    // MARK: - Mutable state (protected by lock)

    private struct EngineState {
        var lastCue: Cue?
        var lastCueTime: Date?
        var cooldownEndTime: Date?
    }

    private let stateLock: OSAllocatedUnfairLock<EngineState>

    // MARK: - Init

    /// Creates a `CueEngine`.
    ///
    /// - Parameters:
    ///   - evaluator: The pure evaluator. Defaults to `CueEvaluator()`.
    ///   - cueCooldownSeconds: Quiet period after every cue emission.
    ///   - minRepeatIntervalSeconds: Minimum gap before the same cue text repeats.
    ///   - clock: Injectable time source — defaults to `{ Date() }`. Override in tests
    ///     to control time precisely without real delays.
    public init(
        evaluator: CueEvaluator = CueEvaluator(),
        cueCooldownSeconds: Double = CueEngine.defaultCueCooldownSeconds,
        minRepeatIntervalSeconds: Double = CueEngine.defaultMinRepeatIntervalSeconds,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.evaluator = evaluator
        self.cueCooldownSeconds = cueCooldownSeconds
        self.minRepeatIntervalSeconds = minRepeatIntervalSeconds
        self.clock = clock
        self.stateLock = OSAllocatedUnfairLock(initialState: EngineState())
    }

    // MARK: - Processing

    /// Processes a `SignalFrame` and returns the selected cue (or `nil` for silence).
    ///
    /// Call from any thread — protected by `OSAllocatedUnfairLock`.
    ///
    /// Returns `nil` when:
    /// - The evaluator finds no active coaching need (all signals good or absent).
    /// - A cue was just emitted and the cadence-cap cooldown is active.
    /// - The candidate cue text was recently emitted and the repeat interval has not elapsed.
    public func process(frame: SignalFrame) -> Cue? {
        guard let candidate = evaluator.evaluate(frame: frame) else { return nil }

        let now = clock()

        return stateLock.withLock { state in
            // Cadence cap: suppress cues while within the cooldown window — UNLESS the
            // candidate has strictly higher priority (lower rawValue) than the last cue.
            // A higher-priority hazard (e.g. stability) should never be blocked by an
            // in-progress cooldown triggered by a lower-priority cue (e.g. composition).
            if let cooldownEnd = state.cooldownEndTime, now < cooldownEnd {
                let bypassCooldown: Bool
                if let last = state.lastCue {
                    bypassCooldown = candidate.priority < last.priority
                } else {
                    bypassCooldown = false
                }
                guard bypassCooldown else { return nil }
            }

            // Repeat suppression: same cue text cannot fire within minRepeatIntervalSeconds.
            if let last = state.lastCue,
               let lastTime = state.lastCueTime,
               candidate.text == last.text,
               now.timeIntervalSince(lastTime) < minRepeatIntervalSeconds {
                return nil
            }

            // Emit cue — record time and set cooldown.
            state.lastCue = candidate
            state.lastCueTime = now
            state.cooldownEndTime = Date(timeInterval: cueCooldownSeconds, since: now)
            return candidate
        }
    }
}
