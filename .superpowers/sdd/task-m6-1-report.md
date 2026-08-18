# Task M6-1 Report — PredictiveCoach + CueEvaluator integration

## Status
DONE_WITH_CONCERNS

## Commits
- `0a5efe9` feat(m6-1): PredictiveCoach + CueEvaluator predictive path

## Test summary
Command: `xcodebuild test -scheme PicPal -destination "id=1E3689DB-800A-4BA8-9396-579F6D67E8D3"`
Result: 614/615 passing. 29 new tests added (13 state machine + 16 evaluator integration).
Pre-existing failure: `SignalTrendDetectorTests.swift:252` — "respects custom window seconds" — floating-point precision bug in `SignalTrendDetector.record` that predates M6-1 (failed before any changes were made). Unrelated to this task.

## Self-review findings and fixes

### 1. Public API visibility constraint (caught during compile)
The brief showed `public func evaluate(frame:predictive:)` but `PredictiveActions` references `PredictiveCoach.Action`, which is internal. Making the full chain public would require `SignalTrendDetector` (M6-0) to become public — an unacceptable change. **Resolution**: Used the two-method pattern:
- `public func evaluate(frame: SignalFrame) -> Cue?` — existing public API unchanged, delegates to internal with `.noAction`.
- `func evaluate(frame: SignalFrame, predictive: PredictiveActions) -> Cue?` — new internal overload with full predictive logic.
Same pattern applied to `CueEngine.process`. All existing call sites work. M6-4 can call the internal overloads within the module.

### 2. `PredictiveCoach.Action` and `.State` Sendable conformance
Swift 6 strict concurrency requires explicit `Sendable` on nested enums used inside `Sendable`-conforming containers. Added `: Sendable` to both `Action` and `State`.

### 3. `BodySignal` initializer requires `confidence:` parameter
The brief's test pseudocode used `BodySignal(hint:dominantRect:)` but the actual struct requires `confidence: Float`. Fixed in `CueEvaluatorPredictiveTests.swift`.

### 4. Test file line-count violation
Initial `PredictiveCoachTests.swift` was 360 lines — over the 300-line limit. Split into:
- `PredictiveCoachTests.swift` (171 lines) — state machine cycle tests.
- `CueEvaluatorPredictiveTests.swift` (193 lines) — CueEvaluator integration tests.

## Acceptance criteria check
- [x] `defaultWaitWindowSeconds = 2.5`; no bare `2.5` anywhere.
- [x] `.emitPositiveCue` when `isWithinThreshold=true` and state was `.waiting`.
- [x] `.emitPredictiveHint` on first improving frame (idle → waiting).
- [x] `.silent` during wait window on subsequent improving frames.
- [x] `.revertToCorrective` on timeout or trend reversal.
- [x] `CueEvaluator.evaluate` accepts `predictive:` (as internal overload; public one-arg delegates).
- [x] `.silent` suppresses corrective but lower-priority cues still fire (blur, framing tested).
- [x] Blur cue (`holdStill`) never affected by predictive.
- [x] Obstruction (`.obstruction` priority) never suppressed.
- [x] All predictive strings are named constants in `CueText`.
- [x] `CueEngine.process` backward-compatible — public one-arg delegates to internal.
- [x] All files ≤ 300 lines (CueEngine.swift 286, PredictiveCoach.swift 134, CueText.swift 88, PredictiveCoachTests.swift 171, CueEvaluatorPredictiveTests.swift 193).
- [x] 29 new Swift Testing tests; all passing.
- [x] `xcodebuild test` passes (614/615 — 1 pre-existing failure).

## Concerns
**Pre-existing test failure** (`customWindowSeconds` in `SignalTrendDetectorTests.swift`): floating-point imprecision in `SignalTrendDetector.record`. When `windowSeconds=0.3` and a sample is exactly 0.3 seconds old, `0.4 - 0.1` in IEEE 754 equals ~0.30000000000000004, which is `>` the window, so the sample is dropped. The test expects `.improving` but gets `.stable`. This was failing before M6-1 changes. Recommend a follow-up fix: use `<` instead of `<=` in the filter, or add a small epsilon.

**`tiltNearlyThere`** constant is added to `CueText` but not yet wired into the evaluator (no use site exists in M6-1 scope). The brief lists it as a string to add — it is available for M6-4 or later to use.

**No `project.yml` changes needed**: the source directory is scanned recursively; xcodegen was re-run to register the new files in `PicPal.xcodeproj`.
