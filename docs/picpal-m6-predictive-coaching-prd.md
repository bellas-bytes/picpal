# Product Requirements Document: M6 — Predictive Coaching + Group-Aware Multi-Person

**Version**: 1.0
**Date**: 2026-08-18
**Author**: Sarah (Product Owner)
**Quality Score**: 94/100
**Companion to**: [picpal-phase2-launch-prd.md](picpal-phase2-launch-prd.md) · [picpal-tickets-m6.md](picpal-tickets-m6.md) · [picpal-build-order.md](picpal-build-order.md)

---

## Executive Summary

M6 upgrades PicPal's coaching voice from purely reactive to situationally aware. Two capabilities ship together: **predictive coaching**, which recognises when a scene is actively improving and waits rather than nagging; and **group-aware multi-person cues**, which handles the "take a photo of all of us" scenario that single-subject body coaching cannot address.

Both capabilities run entirely on-device, reuse existing Vision infrastructure from M2, and integrate into the single cue engine already established in M1. No new ML model is required. The milestone completes the coaching experience described in the Phase 1 PRD and positions PicPal for the M7 TestFlight beta.

---

## Problem Statement

**Current situation (post-M5.5):** The coaching pipeline is correct and fast, but it has two behavioural gaps that testers consistently notice:

1. **Premature corrective cues.** When a photographer is actively tilting the phone toward level, or gradually unblocking a lens, the app keeps saying "level it out" or "exposure off" — coaching a problem the user is already fixing. This feels robotic and slightly annoying, and it directly threatens the non-annoyance KPI.

2. **Single-subject blindness in group shots.** When ≥2 people are in frame, the existing landmark pipeline treats whoever the dominant body is as the sole subject. People getting cropped at frame edges go un-coached; headroom and thirds cues become meaningless for groups.

**Proposed solution:**

- A `SignalTrendDetector` tracks rolling slopes for tilt and exposure signals. When slope exceeds an improvement threshold, a `PredictiveCoach` state machine suppresses the corrective cue, emits a single encouraging hint ("almost level"), and waits up to 2.5 s for the condition to self-resolve. On success it emits a positive confirmation; on timeout it falls back to the standard corrective.
- A `GroupPresenceDetector` reuses existing `VNHumanBodyPoseObservation` output from `LandmarkOrchestrator` to detect ≥2 qualified persons. When group mode is active, body-positioning cues describe the group ("someone's getting cut off on the right — back up a bit") and suppress single-subject headroom/placement cues. Transitions are hysteresis-gated to prevent flicker.

**Business impact:** Coaching that waits when it should wait and speaks to groups correctly reduces annoyance, increases session length, and gives M7 beta testers a materially more polished experience to evaluate.

---

## Success Metrics

**Carry-forward KPIs (must not regress from M4 baseline):**
- Perceived real-time responsiveness: ≥70% of session-survey respondents agree feedback came fast enough to act on.
- Non-annoyance: median coaching cues per stable episode ~1–3.
- Tier-0/0.5 actionable latency: <150ms from stable frame to first cue.

**New M6 KPIs:**

| KPI | Target | Measurement mechanism |
|-----|--------|----------------------|
| Predictive hint accuracy | ≥60% of issued hints resolve to threshold within the wait window | `CueEvent` telemetry gains `predictiveHintIssued: Bool` and `predictiveHintOutcome: .resolved / .reverted / .expired` fields — exported via `TelemetryExporter` |
| Group-shot cue coverage | ≥1 group cue emitted whenever a person is being cropped in a ≥2-person scene | Confirmed during M6-4 moderated validation session; tracked in session findings |
| Per-frame budget | `SignalTrendDetector` + `GroupPresenceDetector` add <2ms to the existing accumulator callback | Measured via the M4 perf harness (`ProcessInfo.thermalState` + frame-time instrumentation) |

**Validation:** M6-4 validation session with the updated demo-script.md scenarios; telemetry export reviewed post-session. Regression is a blocker for merge to develop.

---

## User Personas

*(Carried from Phase 1 PRD — abbreviated for M6 relevance)*

### Co-Primary A: Casual Cam
Shooting everyday scenes. Zero setup tolerance. Hears corrective cues while actively fixing the shot and finds them unhelpful. M6 directly addresses their annoyance point.

### Co-Primary B: Sharing Sam
Handed a phone to photograph a group of friends. Hears single-subject cues that don't help — the real problem is someone being cut off at the edge. Group-aware cues are built for this scenario.

---

## User Stories & Acceptance Criteria

### Story 1: Predictive wait — tilt

**As a** photographer who is already tilting the phone toward level
**I want** the app to recognise I'm fixing it and wait rather than repeat the corrective cue
**So that** coaching feels helpful rather than robotic.

**Acceptance Criteria:**
- [ ] When tilt is outside threshold *and* the rolling slope exceeds `improvementSlopeThreshold` (default 0.03 units/s), a predictive hint fires once ("almost level") instead of the corrective cue.
- [ ] The hint fires exactly once per improvement episode — subsequent improving frames are silent during the 2.5 s wait window.
- [ ] If tilt reaches threshold within the window: a positive confirmation cue fires once ("that's it"), then coaching goes quiet.
- [ ] If tilt has not reached threshold after 2.5 s: the standard corrective cue resumes.
- [ ] If improvement stalls or reverses during the window: the corrective cue resumes immediately (no wait-window penalty).
- [ ] Blur/shake corrective cues are **never** subject to predictive suppression.
- [ ] Obstruction and stability (tier-0 emergency) cues are **never** suppressed regardless of trend state.
- [ ] Telemetry records `predictiveHintIssued = true` and the eventual `predictiveHintOutcome`.

### Story 2: Predictive wait — exposure

**As a** photographer gradually unblocking their lens or moving into better light
**I want** the coaching to pause "exposure off" while I'm improving the situation
**So that** I don't hear the same warning while I'm actively fixing it.

**Acceptance Criteria:**
- [ ] Same gating logic as tilt: hint fires once ("light's getting better, hold a moment"), then silent during window.
- [ ] Positive confirmation fires on recovery ("nice light").
- [ ] Reverts to corrective on timeout or trend reversal.
- [ ] Predictive path covers only tilt and exposure — blur/shake have no trend tracking.

### Story 3: Group photo coaching

**As a** photographer asked to "get everyone in"
**I want** coaching cues that speak to the whole group — "someone's getting cut off" rather than single-subject headroom advice
**So that** I can actually fix what matters in a group shot.

**Acceptance Criteria:**
- [ ] When ≥2 persons are detected with sufficient confidence for N consecutive frames (N = existing cadence-controller debounce), group mode activates.
- [ ] In group mode, single-subject body-positioning cues (headroom, gaze, awkward crop from `frame.body`) are suppressed; group cues fire instead.
- [ ] Group cue priority (highest to lowest within group): edge cutoff left/right > spread too wide > lean in > group too high.
- [ ] Group mode deactivates after <2 persons are detected for N consecutive frames (hysteresis prevents flicker when a person briefly leaves frame).
- [ ] Lens obstruction cue (`lensObstructed`, obstruction priority) fires in group mode — it is never suppressed.
- [ ] No per-person addressing — cues describe the group ("someone's getting cut off on the right"), never an individual.
- [ ] When `groupPresence == nil` (single-subject or no person), existing M2 body-cue path runs unchanged.

---

## Functional Requirements

### Feature 1: SignalTrendDetector

**File**: `picpal/Sources/CueEngine/SignalTrendDetector.swift`

Pure value-computing type — no UIKit, no Vision, no side effects. Tracks rolling sample windows for `tilt` and `exposure` only.

- **API**: `record(signal:value:)` on every frame; `trend(for:) -> Trend` (.improving / .stable / .worsening); `reset()` on scene change.
- **Constants**: `defaultWindowSeconds = 1.5`, `defaultImprovementSlopeThreshold = 0.03`.
- **Slope definition**: both tilt and exposure use absolute values; a negative slope (decreasing) = improving.
- **Determinism**: injectable clock `@escaping @Sendable () -> Date` for unit-testable slope computation without real-time delays.
- **Concurrency**: `OSAllocatedUnfairLock` on sample storage; `@unchecked Sendable`.

### Feature 2: PredictiveCoach

**File**: `picpal/Sources/CueEngine/PredictiveCoach.swift`

One instance per tracked signal (two instances total: tilt, exposure). Manages the wait-window state machine.

- **States**: `.idle` → `.waiting(since:)` → resolved (external) or `.idle` (on revert/timeout).
- **Actions returned per frame**: `.emitPredictiveHint`, `.silent`, `.emitPositiveCue`, `.revertToCorrective`, `.idle`.
- **Wait window**: `defaultWaitWindowSeconds = 2.5`; injectable clock for testing.
- **Positive confirmation** is synthesised externally (in the accumulator callback when signal crosses threshold during `.waiting`), not inside `PredictiveCoach.update`.
- **Reset**: `reset()` called on scene change and background transition.

### Feature 3: CueEvaluator integration (predictive path)

Minimal change to `CueEvaluator`: before emitting a tilt or exposure corrective cue, query `trendDetector.trend(for:)`. If `.improving`, delegate to the relevant `PredictiveCoach` and map the returned `Action` to the emitted cue (or nil). Fall through to the existing corrective cue on `.revertToCorrective`. Blur/shake and all higher-priority cues (obstruction, stability) are not touched.

All predictive cue strings are named constants in `CueText` — no bare string literals.

### Feature 4: GroupPresenceDetector

**File**: `picpal/Sources/Landmarks/GroupPresenceDetector.swift`

Stateless struct. Input: `[VNHumanBodyPoseObservation]` from existing `LandmarkOrchestrator` output (no new Vision inference). Output: `GroupPresence?`.

- Filters observations by `minimumBodyConfidence = 0.4`.
- Returns `nil` if `qualifiedCount < 2`.
- Computes `unionBoundingBox` as the geometric union of all qualified bounding boxes.
- Derives `spreadFraction`, `leftMargin`, `rightMargin`, `headroomFraction` from the union box.
- Vision coordinate space: y-up; `headroomFraction = 1.0 - union.maxY`.

### Feature 5: GroupPresence signal type

**File**: `picpal/Sources/Signals/GroupPresence.swift`

`public struct GroupPresence: Sendable` with `personCount`, `unionBoundingBox`, and four derived fractions. Named threshold constants: `minPersonCount = 2`, `edgeCutoffThreshold = 0.04`, `spreadWideThreshold = 0.90`, `learnInThreshold = 0.55`, `highGroupThreshold = 0.12`.

`SignalFrame` gains `public var groupPresence: GroupPresence?` alongside existing `body: BodySignal?`.

### Feature 6: CueEvaluator group path

After the single-subject body-cue block (at `.bodyPositioning` priority): if `frame.groupPresence != nil`, suppress `frame.body` cues and evaluate the group geometry in priority order: left edge cutoff → right edge cutoff → spread wide → lean in → group too high. If `frame.groupPresence == nil`, skip the group block entirely.

Hysteresis gating is implemented in `GroupPresenceDetector` call site within `LandmarkOrchestrator`, not in `CueEvaluator`. `CueEvaluator` sees a stable `groupPresence` value and branches deterministically.

### Feature 7: Telemetry extension

Extend `CueEvent` (in the existing KPI telemetry from M4-1) with:
- `predictiveHintIssued: Bool` (default `false`)
- `predictiveHintOutcome: PredictiveHintOutcome?` (`.resolved`, `.reverted`, `.expired`) — set when the wait-window episode closes.

Both fields are exported via `TelemetryExporter`. Backward-compatible with existing log format (new optional fields).

### Feature 8: Validation session kit update

`docs/demo-script.md` gains a **Phase 2 Validation** section with three scenario scripts: tilt predictive check, exposure predictive check, group photo check (see M6-4 acceptance criteria for the exact scenario wording).

### Feature 9: DEBUG tuning hooks

`TuningSettings.shared` gains:
- `predictiveWaitWindowSeconds: Double` (default 2.5)
- `trendImprovementSlope: Double` (default 0.03)

Both appear in `TuningPanel`'s "Cue engine" section, matching the existing pattern. No effect in release builds — guarded by `#if DEBUG`.

### Out of Scope

- Per-person addressing in group cues (by design — see Locked Decisions).
- Predictive coaching for blur/shake (no reliable trend).
- New ML model for group detection (reuses existing Vision body observations).
- UI changes (group mode has no visual indicator in M6; audio only).
- Persisting trend or group state across background/foreground cycles.

---

## Technical Constraints

### Performance

- `SignalTrendDetector.record` and `trend(for:)` are pure arithmetic on a small ring buffer — expected <0.1ms per call. Must remain inline in the `SignalFrameAccumulator` callback on the accumulator queue.
- `GroupPresenceDetector.detect` reuses `VNHumanBodyPoseObservation` output already computed by `LandmarkOrchestrator` — no new Vision inference, no separate dispatch. Must run before `accumulator.update(groupPresence:)` on the existing `probeQueue`.
- Both components must keep the combined accumulator callback within the existing <150ms latency budget. Verified using the M4 perf harness.

### Concurrency

- Swift 6 strict concurrency throughout.
- `SignalTrendDetector` and `PredictiveCoach`: `OSAllocatedUnfairLock`-protected, `@unchecked Sendable`.
- `GroupPresence` and `GroupPresenceDetector`: value types, `Sendable` by default.
- Tier-0 forwarding invariant: `downstream?.cameraCapture(...)` remains the first statement in every `CameraFrameDelegate` method. Not negotiable.

### Test coverage

- Swift Testing only (`import Testing`, `@Test`, `#expect`). No XCTest.
- ≥80% coverage on all new logic.
- 300-line file limit on all source and test files.
- Named `static` constants for every threshold and timing value — no bare number literals.

### Integration

- `LandmarkOrchestrator` already outputs `[VNHumanBodyPoseObservation]`; `GroupPresenceDetector` chains onto that output without pipeline changes.
- `SignalFrameAccumulator` gains `update(groupPresence:)` alongside existing `update(body:)`.
- `CueEvaluator` changes are additive (new guard blocks before/within existing sections) — no structural changes to priority ordering.

---

## MVP Scope & Phasing

### Phase 1: M6 (this milestone)

Execution order with dependencies:
```
M6-0: SignalTrendDetector (no deps — pure arithmetic)
  ↓
M6-1: PredictiveCoach + CueEvaluator tilt/exposure integration
M6-2: GroupPresenceDetector + GroupPresence signal  ← parallel with M6-1
  ↓
M6-3: Group cue text + CueEvaluator group path
  ↓
M6-4: Integration verification + demo-script.md update
```

**MVP definition**: all five tasks complete, full test suite passing, validation session produces no regressions against M4 KPIs.

### Future Considerations

- Predictive coaching for focus/depth-of-field signals (requires a reliable trend signal — not available in M1–M6).
- Visual indicator for group mode (e.g., a subtle overlay showing the detected group bounding box) — deferred to post-launch polish.
- Per-person count cap: behavior for 6+ people in frame is unspecified in M6 (union-box geometry still works, but cue relevance degrades at high counts).

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Slope threshold too aggressive — predictive hints fire on noise | Medium | Medium | Injectable clock enables regression tests; `TuningSettings.trendImprovementSlope` allows in-session adjustment without rebuild |
| Group mode flicker when person briefly leaves frame | Medium | Low | Hysteresis gate (N consecutive frames, matching existing cadence debounce) prevents rapid mode switching |
| `GroupPresenceDetector` confidence threshold too strict — group not detected at low frame rates | Low | Medium | `minimumBodyConfidence = 0.4` matches M2 presence-gate value; validated in M6-4 session |
| Predictive wait window feels too long (2.5s) | Low | Medium | `TuningSettings.predictiveWaitWindowSeconds` configurable in debug; default may be tuned down post-M7 beta feedback |
| Telemetry extension breaks existing log format | Low | Low | New fields are optional with default values; backward-compatible with existing TelemetryExporter |

---

## Dependencies & Blockers

**Dependencies:**
- M5.5 fully merged to `develop` ✅ — all existing signal, landmark, and cue-engine infrastructure is in place.
- `LandmarkOrchestrator` outputs `[VNHumanBodyPoseObservation]` from M2 ✅ — no changes needed to the Vision inference pipeline.
- M4 `TuningSettings` and `TuningPanel` pattern ✅ — debug tuning hooks follow existing conventions.

**Known blockers:** None. M6-0 and M6-2 have no upstream dependencies and can begin immediately.

---

## Appendix

### Glossary

- **SignalTrendDetector**: Tracks rolling slopes for tilt and exposure signals over a 1.5 s window.
- **PredictiveCoach**: Per-signal state machine managing the wait-window lifecycle (idle → waiting → resolved/reverted).
- **GroupPresence**: Value type describing detected group geometry (person count, union bounding box, derived fractions).
- **GroupPresenceDetector**: Stateless struct computing `GroupPresence?` from existing Vision body-pose observations.
- **Hysteresis gate**: Mode transitions require N consecutive frames in the new state before the switch completes — prevents flicker.
- **Wait window**: 2.5 s period after a predictive hint is issued during which corrective cues are suppressed.
- **improvementSlopeThreshold**: 0.03 units/second — minimum rate of decrease required to classify a signal as `improving`.

### References

- [picpal-tickets-m6.md](picpal-tickets-m6.md) — implementation task specs with exact API signatures and acceptance criteria
- [picpal-phase2-launch-prd.md](picpal-phase2-launch-prd.md) — Phase 2 KPIs and personas
- [picpal-build-order.md](picpal-build-order.md) — milestone dependency graph
- [demo-script.md](demo-script.md) — validation session kit (updated in M6-4)

---

*This PRD was created through interactive requirements gathering with quality scoring to ensure comprehensive coverage of business, functional, UX, and technical dimensions.*
