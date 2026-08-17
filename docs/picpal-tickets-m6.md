# PicPal — M6 Tickets (Predictive Coaching + Group-Aware Multi-Person)

**Companion to**: [picpal-build-order.md](picpal-build-order.md) · [picpal-phase2-launch-prd.md](picpal-phase2-launch-prd.md)
**Date**: 2026-08-11
**Platform**: iOS (Swift 6, Vision)
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

> **Milestone target**: Coaching shifts from purely reactive to situationally aware. When a scene is actively improving, the app waits rather than nagging. When ≥2 people are in frame, the app speaks to the group.

## Locked decisions

1. **Predictive hints apply only to tilt and exposure** — not blur/shake (unpredictable, no reliable trend). This is a hard constraint, not a tuning default.
2. **Trend detector is additive — CueEvaluator changes are minimal** — `SignalTrendDetector` runs alongside the existing signal path. `CueEvaluator` checks trend state before emitting corrective cues for tilt and exposure. No structural changes to the existing cue priority ordering.
3. **Wait window: 2.5s by default** (`PredictiveCoach.defaultWaitWindowSeconds = 2.5`). After the window, the system re-evaluates and either fires a positive cue (if threshold crossed) or reverts to the corrective cue.
4. **Group-aware mode at ≥2 confirmed persons** — uses the same Vision body detection that `PresenceGate` (M2-1) already performs. No new ML model.
5. **No per-person addressing** — group cues describe the group, never an individual. "Someone's getting cut off on the right" — never "the person on the left."
6. **Group cues integrate at `.bodyPositioning` priority** — same level as M2 body cues. Group mode does not suppress single-subject body cues; it replaces headroom/placement cues with group-level equivalents.

## Conventions (carried from M0–M4)

- Swift 6 strict concurrency; `OSAllocatedUnfairLock` for all shared state.
- **Swift Testing only** (`import Testing`), ≥80% coverage on new logic.
- 300-line file limit; no magic numbers (named `static` constants).
- Tier-0 forwarding invariant: unchanged.
- Immutable `SignalFrame` snapshots — `SignalTrend` and `GroupPresence` are value types.

## Execution order

```
M6-0 (SignalTrendDetector — pure, no deps)
  ↓
M6-1 (predictive cue integration into CueEvaluator + wait timer)
M6-2 (GroupPresenceDetector + GroupPresence signal type)  ← can run in parallel with M6-1
  ↓
M6-3 (group-level cue text + CueEvaluator group path)
  ↓
M6-4 (validation session update + integration verification)
```

---

## M6-0 — SignalTrendDetector
**Size**: M · **Deps**: none

**Goal**: Track rolling signal values over a configurable time window and compute whether a signal is actively improving. Pure value-computing type — no UIKit, no Vision, no side effects.

**File**: `picpal/Sources/CueEngine/SignalTrendDetector.swift`

```swift
import Foundation

/// Tracks whether Tier-0 signals are actively improving toward their thresholds.
/// Only tilt and exposure are tracked — blur/shake have no reliable trend.
final class SignalTrendDetector: @unchecked Sendable {

    enum TrackedSignal { case tilt, exposure }

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
        guard samples.count >= 2 else { return .stable }
        let duration = samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp)
        guard duration > 0 else { return .stable }
        let slope = (samples.last!.value - samples.first!.value) / duration
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
```

**ContentView wiring (added in M6-1)**: create `SignalTrendDetector` in `wireUp()`; call `record(signal:value:)` each frame from the `SignalFrameAccumulator` callback.

**Acceptance criteria**

- [ ] `trend(for:)` returns `.stable` with fewer than 2 samples.
- [ ] `.improving` returned when all samples in the window show a decreasing trend exceeding `improvementSlopeThreshold`.
- [ ] `.worsening` returned when trend is increasing.
- [ ] `.stable` returned when slope is within ±`improvementSlopeThreshold`.
- [ ] Samples outside the time window are trimmed on each `record` call.
- [ ] `reset()` clears all samples; `trend(for:)` returns `.stable` after reset.
- [ ] Injectable clock enables deterministic slope testing without real delays.
- [ ] Unit tests: `SignalTrendDetectorTests.swift` — improving/stable/worsening for each signal, window trimming, reset, concurrent record + trend calls.

---

## M6-1 — Predictive coaching: CueEvaluator + wait timer
**Size**: M · **Deps**: M6-0

**Goal**: Gate corrective tilt and exposure cues when the signal is actively improving; emit a predictive hint instead. After the wait window, emit a positive cue on success or revert to corrective on stall.

### New cue text in CueText (or wherever existing tilt/exposure text lives)

Read the existing cue text location before adding. New named strings:

```swift
// Predictive hints (emitted while waiting)
static let tiltAlmostLevel      = "almost level"
static let tiltNearlyThere      = "just a touch more"
static let exposureImproving    = "light's getting better, hold a moment"

// Positive confirmation (emitted after threshold crossed)
static let tiltConfirmed        = "that's it"
static let exposureConfirmed    = "nice light"
```

### PredictiveCoach

**File**: `picpal/Sources/CueEngine/PredictiveCoach.swift`

```swift
import Foundation

/// Manages the wait-window state for predictive coaching.
/// One instance per tracked signal. Stateful — held in ContentView.
final class PredictiveCoach: @unchecked Sendable {

    static let defaultWaitWindowSeconds: Double = 2.5

    enum State: Equatable {
        case idle
        case waiting(since: Date)
        case confirmed
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let waitWindowSeconds: Double
    private let clock: @Sendable () -> Date

    init(waitWindowSeconds: Double = defaultWaitWindowSeconds, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.lock = OSAllocatedUnfairLock(initialState: .idle)
        self.waitWindowSeconds = waitWindowSeconds
        self.clock = clock
    }

    /// Call each frame with the current trend and whether the signal is within threshold.
    /// Returns the action to take this frame.
    enum Action {
        case emitPredictiveHint   // suppress corrective cue, say "almost there"
        case emitPositiveCue      // threshold crossed within window — say "that's it"
        case revertToCorrective   // window expired, still outside threshold
        case silent               // trend improving and window not expired — just wait
        case idle                 // signal within threshold or trend not improving
    }

    func update(trend: SignalTrendDetector.Trend, isWithinThreshold: Bool) -> Action {
        lock.withLock { state in
            let now = clock()
            switch (trend, isWithinThreshold, state) {
            case (_, true, _):
                state = .idle
                return .idle
            case (.improving, false, .idle):
                state = .waiting(since: now)
                return .emitPredictiveHint
            case (.improving, false, .waiting(let since)):
                if now.timeIntervalSince(since) >= waitWindowSeconds {
                    state = .idle
                    return .revertToCorrective
                }
                return .silent
            case (.worsening, _, _), (.stable, false, .waiting):
                state = .idle
                return .revertToCorrective
            case (.confirmed, _, _):
                state = .idle
                return .emitPositiveCue
            default:
                return .idle
            }
        }
    }

    func reset() { lock.withLock { $0 = .idle } }
}
```

Note: `confirmed` is not a `SignalTrendDetector.Trend` case — it is synthesized externally. When the signal crosses threshold after being in `.waiting` state, the CueEvaluator transition emits `.emitPositiveCue`. This is handled in `ContentView+Session` logic (see below), not inside `PredictiveCoach.update`.

### CueEvaluator integration

Read `picpal/Sources/CueEngine/CueEvaluator.swift`. Tilt and exposure corrective cues are identified by their existing code paths. The change is minimal:

```swift
// Before emitting a tilt corrective cue:
if trendDetector.trend(for: .tilt) == .improving {
    let action = tiltCoach.update(trend: .improving, isWithinThreshold: false)
    switch action {
    case .emitPredictiveHint: return Cue(text: CueText.tiltAlmostLevel, ...)
    case .silent: return nil
    case .revertToCorrective: break  // fall through to existing corrective cue
    default: break
    }
}
// ... existing corrective cue logic ...
```

The same pattern applies to the exposure corrective cue path.

### ContentView+Session integration

- Create two `PredictiveCoach` instances in `wireUp()`: one for tilt, one for exposure.
- Call `trendDetector.record(signal: .tilt, value: abs(signalFrame.tilt.angle))` and `record(signal: .exposure, value: abs(signalFrame.exposure.deviation))` each frame in the accumulator callback.
- Call `trendDetector.reset()` and both coaches' `reset()` on scene change (existing `onSceneChange` hook).
- Pass `trendDetector` to `CueEvaluator` (or query it in the accumulator callback before `engine.process(frame:)` — whichever is cleaner given the current architecture; read `CueEvaluator.swift` to decide).

**Acceptance criteria**

- [ ] When tilt signal is improving (slope < −threshold), the corrective tilt cue is suppressed and a predictive hint fires instead on the first frame of `.improving` trend.
- [ ] Predictive hint fires at most once per `.waiting` window (subsequent improving frames are `.silent`).
- [ ] After `waitWindowSeconds` without reaching threshold: revert to standard corrective cue.
- [ ] When the signal crosses threshold during the wait window: positive confirmation cue fires once.
- [ ] Blur/shake corrective cues are **never** subject to predictive suppression — no `SignalTrendDetector` entry for blur.
- [ ] Obstruction and stability (tier-0 emergency) cues are **never** suppressed by the predictive path — they have higher priority and emit before the tilt/exposure check.
- [ ] `PredictiveCoach.defaultWaitWindowSeconds = 2.5`; no bare `2.5`.
- [ ] All predictive cue strings are named constants in `CueText` (or equivalent location); no bare string literals.
- [ ] `trendDetector.reset()` and `coach.reset()` are called on scene change.
- [ ] Unit tests: `PredictiveCoachTests.swift` — full state machine cycle (idle → waiting → confirmed; idle → waiting → revert); predictive hint suppresses corrective for tilt and exposure; blur/stability cues unaffected (verify in `CueEvaluatorTests` or integration test).

---

## M6-2 — GroupPresenceDetector + GroupPresence signal
**Size**: M · **Deps**: none (uses existing Vision body observation output from `LandmarkOrchestrator`)

**Goal**: Detect when ≥2 people are in frame and compute group-level geometry (bounding-box union, spread, edge proximity). Feeds a `GroupPresence` value into `SignalFrame` for the cue path.

### GroupPresence signal type

**File**: `picpal/Sources/Signals/GroupPresence.swift`

```swift
import Foundation

/// Group-level framing geometry. Populated when ≥2 persons are detected.
public struct GroupPresence: Sendable {

    /// Number of detected persons with sufficient confidence.
    public let personCount: Int

    /// Union bounding box of all detected persons, normalized (Vision coords, y-up).
    public let unionBoundingBox: CGRect

    /// Fraction of frame width occupied by the group.
    public let spreadFraction: Float

    /// Normalized distance from left edge of union box to left frame edge.
    public let leftMargin: Float

    /// Normalized distance from right frame edge to right edge of union box.
    public let rightMargin: Float

    /// Normalized headroom above the union box.
    public let headroomFraction: Float

    /// Named thresholds.
    public static let minPersonCount: Int = 2
    public static let edgeCutoffThreshold: Float = 0.04   // within 4% of frame edge → cut off
    public static let spreadWideThreshold: Float = 0.90   // group fills >90% of width → too wide
    public static let learnInThreshold: Float = 0.55      // group spread > 55% but not wide → lean in
    public static let highGroupThreshold: Float = 0.12    // headroom < 12% → group too high
}
```

Add `public var groupPresence: GroupPresence?` to `SignalFrame` (alongside existing `body: BodySignal?`). Set to `nil` when `personCount < 2` or confidence insufficient.

### GroupPresenceDetector

**File**: `picpal/Sources/Landmarks/GroupPresenceDetector.swift`

```swift
import Vision

/// Computes GroupPresence from an array of body pose observations.
/// Called inside LandmarkOrchestrator's probeQueue after Vision inference completes.
struct GroupPresenceDetector {

    static let minimumBodyConfidence: Float = 0.4

    /// Returns GroupPresence when ≥2 observations meet the confidence threshold; nil otherwise.
    func detect(from observations: [VNHumanBodyPoseObservation]) -> GroupPresence? {
        let qualified = observations.filter { $0.confidence >= Self.minimumBodyConfidence }
        guard qualified.count >= GroupPresence.minPersonCount else { return nil }
        let boxes = qualified.map { $0.boundingBox }
        let union = boxes.reduce(boxes[0]) { $0.union($1) }
        return GroupPresence(
            personCount: qualified.count,
            unionBoundingBox: union,
            spreadFraction: Float(union.width),
            leftMargin: Float(union.minX),
            rightMargin: Float(1.0 - union.maxX),
            headroomFraction: Float(1.0 - union.maxY)  // Vision y-up: 1.0 is top
        )
    }
}
```

### LandmarkOrchestrator integration

Read `picpal/Sources/Landmarks/LandmarkOrchestrator.swift`. After running body pose inference and before calling `onBodySignal`, call `GroupPresenceDetector().detect(from: bodyObservations)` and include the result in the `SignalFrame` update.

The `SignalFrameAccumulator` gains `func update(groupPresence: GroupPresence?)` alongside existing `update(body:)`. The `accumulator.update(groupPresence:)` call is chained immediately after `accumulator.update(body:)` in `LandmarkOrchestrator`.

**Acceptance criteria**

- [ ] `GroupPresence` defined in `Sources/Signals/`; all threshold constants are named.
- [ ] `GroupPresenceDetector.detect` returns `nil` with 0 or 1 observations above the confidence floor.
- [ ] `detect` returns a `GroupPresence` with correct `personCount`, `unionBoundingBox`, and derived fractions for 2+ observations.
- [ ] `unionBoundingBox` is the true geometric union of all qualified observation bounding boxes.
- [ ] `leftMargin` and `rightMargin` are computed correctly from the union box edges.
- [ ] `SignalFrame.groupPresence` is `nil` when `personCount < 2` and non-nil when `personCount ≥ 2`.
- [ ] Tier-0 forwarding invariant holds in `LandmarkOrchestrator` — `downstream?.cameraCapture(...)` is still the first statement.
- [ ] Unit tests: `GroupPresenceDetectorTests.swift` — nil for 0 and 1 observations, correct geometry for 2 and 3 observations, confidence filtering.

---

## M6-3 — Group-level cue text + CueEvaluator group path
**Size**: S · **Deps**: M6-2

**Goal**: Map `GroupPresence` geometry to coached cues in `CueEvaluator`. Group cues integrate at `.bodyPositioning` priority and do not suppress obstruction or stability cues.

### Group cue text (add to existing cue text location)

```swift
enum GroupCueText {
    static let someoneCutOffLeft   = "someone's getting cut off on the left — back up a bit"
    static let someoneCutOffRight  = "someone's getting cut off on the right — back up a bit"
    static let groupTooWide        = "the group is spread wide — back up a touch"
    static let learnIn             = "have everyone lean in a little"
    static let groupTooHigh        = "the group's a bit high — tilt down slightly"
}
```

### CueEvaluator group path

Read `picpal/Sources/CueEngine/CueEvaluator.swift`. Add a group-cue block after the existing body-signal block, at the same priority level (`.bodyPositioning`):

```swift
if let group = frame.groupPresence {
    // Priority within group cues: edge cutoff > spread wide > lean in > headroom
    if group.leftMargin < GroupPresence.edgeCutoffThreshold {
        return Cue(text: GroupCueText.someoneCutOffLeft, priority: .bodyPositioning, sourceTier: .tier05)
    }
    if group.rightMargin < GroupPresence.edgeCutoffThreshold {
        return Cue(text: GroupCueText.someoneCutOffRight, priority: .bodyPositioning, sourceTier: .tier05)
    }
    if group.spreadFraction > GroupPresence.spreadWideThreshold {
        return Cue(text: GroupCueText.groupTooWide, priority: .bodyPositioning, sourceTier: .tier05)
    }
    if group.spreadFraction > GroupPresence.learnInThreshold {
        return Cue(text: GroupCueText.learnIn, priority: .bodyPositioning, sourceTier: .tier05)
    }
    if group.headroomFraction < GroupPresence.highGroupThreshold {
        return Cue(text: GroupCueText.groupTooHigh, priority: .bodyPositioning, sourceTier: .tier05)
    }
}
```

When `frame.groupPresence != nil`, **single-subject body cues** (`frame.body`) are suppressed — group mode takes over the body-positioning slot. Obstruction (`lensObstructed`) is detected at obstruction priority (above body positioning) and is NOT suppressed.

**Acceptance criteria**

- [ ] All `GroupCueText` strings are named constants; no bare string literals.
- [ ] Group cues fire at `CuePriority.bodyPositioning` (not a new priority level).
- [ ] Priority ordering within group cues matches the spec: edge cutoff > wide > lean in > headroom.
- [ ] When `frame.groupPresence != nil`: single-subject body cues (headroom, gaze, crop from `frame.body`) are suppressed in favor of group cues.
- [ ] When `frame.groupPresence == nil`: group cue block is skipped; existing single-subject body cue path runs unchanged.
- [ ] `lensObstructed` (obstruction priority) is never suppressed by group mode.
- [ ] Unit tests: `CueEvaluatorGroupTests.swift` — each group cue fires at the correct geometry threshold; single-subject cues suppressed in group mode; obstruction cue fires in group mode; no group cue when `groupPresence == nil`.

---

## M6-4 — Integration + validation session update
**Size**: S · **Deps**: M6-1, M6-3

**Goal**: Verify the full predictive + group pipeline works end-to-end; update the M4 validation session kit with M6 test scenarios.

### Validation session kit update

Read `docs/demo-script.md`. Add a **Phase 2 validation** section:

**Predictive coaching check** (tilt signal):
1. Hold the phone at a noticeable tilt (~15°).
2. Slowly bring it toward level at a steady rate.
3. Expected: app says "almost level" (or variant) instead of "level it out"; does NOT repeat the hint during the wait window; says "that's it" when level is reached.
4. If hint does not appear and you still hear "level it out", record in findings.

**Predictive coaching check** (exposure):
1. Cover part of the lens to cause exposure issues; gradually uncover.
2. Expected: app says "light's getting better, hold a moment" during the trend; positive cue on recovery.

**Group photo check**:
1. Have 2–3 people stand in frame; ensure at least one is near a frame edge.
2. Expected: "someone's getting cut off on the right — back up a bit" (or equivalent direction).
3. Back up until all are within frame.
4. Expected: group coaching stops; frame-level coaching resumes.

**Acceptance criteria**

- [ ] `demo-script.md` includes the three Phase 2 checks above with expected vs. failure criteria.
- [ ] `SignalTrendDetector`, `PredictiveCoach`, and `GroupPresenceDetector` are all initialized in `wireUp()` and wired into the accumulator callback path.
- [ ] Scene-change hook resets `SignalTrendDetector` and both `PredictiveCoach` instances.
- [ ] Background transition resets `SignalTrendDetector` (call `reset()` alongside `settleEventTimer?.reset()` in `handleScenePhaseChange`).
- [ ] In DEBUG: `TuningSettings.shared` gains `predictiveWaitWindowSeconds` and `trendImprovementSlope` properties (following the existing TuningSettings pattern) so these can be tuned without rebuilds. Both show in `TuningPanel`'s "Cue engine" section.
- [ ] All tests from M6-0 through M6-3 pass (`xcodebuild test`).
