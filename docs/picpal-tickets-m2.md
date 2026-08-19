# PicPal — M2 Tickets (Tier 0.5 · Body-Aware Coaching)

**Companion to**: [picpal-build-order.md](picpal-build-order.md) · [m2-body-aware-coaching-prd.md](m2-body-aware-coaching-prd.md) · [m0-5-landmark-spike.md](m0-5-landmark-spike.md)
**Date**: 2026-08-11
**Platform**: iOS (Swift 6, Vision, **MediaPipe Tasks Vision**, CoreMotion)
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

> **Milestone target**: With a person in frame, the app catches lens obstruction, awkward crops, gaze-away, and headroom in real time — and produces **zero false body cues** when no person is present or confidence is low. No VLM.

## Locked decisions (2026-08-11)

1. **Hybrid stack** — Apple Vision (presence + body pose) + MediaPipe (hand + face landmarks). Signal ownership fixed per ticket below.
2. **Defensive YELLOW cadence** — landmark models run on **settled frames only, ≤5 fps, presence-gated**. Never assumes GREEN.
3. **M0-5 gate: PASSED YELLOW** — on-device iPhone 17 run measured **VisionTotal p95 ≈ 140.7 ms** (Body 32.2 / Hand 84.1 / Face 24.3), thermal nominal. Within the <150 ms budget → proceed as specced. **Hand is the dominant cost (84.1 ms)** — M2-0 must re-measure it under MediaPipe before both stacks are committed.

## Conventions (carried from M0/M1)

- Every signal producer writes an immutable snapshot into `SignalFrame`; producers are pure — they compute, they don't speak. M2 adds a single `BodySignal` field.
- Swift 6 strict concurrency (`@unchecked Sendable` + `OSAllocatedUnfairLock`; `nonisolated` delegate methods).
- **Swift Testing** only (`import Testing`), ≥80% coverage on new logic.
- 300-line file limit; no magic numbers (named `static` constants).
- M0-4 perf/thermal telemetry stays on — watch it every ticket now that a second model path is live.

---

## M2-0 — MediaPipe integration spike + unified coordinate layer  ⚠ SPIKE
**Size**: L · **Deps**: M1 complete · **Risk-critical**
Settle how MediaPipe ships in this project and prove the hand-model latency before feature work commits to the hybrid stack. Produces a go/no-go on MediaPipe Hand + Face, not shippable cues.
**Acceptance criteria**
- [ ] MediaPipe Tasks Vision added to the build (CocoaPods **or** binary xcframework/SPM — pick one, document why; must coexist with the current xcodegen setup).
- [ ] `hand_landmarker.task` and `face_landmarker.task` bundled in-app; both load and run in `.video` mode with monotonic timestamps against the live feed.
- [ ] **Latency re-measured on-device**: MediaPipe Hand and Face p95 recorded via the M0-4 harness and compared to the Vision baseline (Hand 84.1 ms). Combined Vision-body + MediaPipe-hand + MediaPipe-face p95 documented against the 150 ms budget.
- [ ] **Unified coordinate helper**: one tested pure function converting Vision (normalized, bottom-left) **and** MediaPipe (normalized, top-left) landmarks to the app's UIKit top-left convention (mirrors the existing `visionRectToSwiftUI` pattern).
- [ ] Written go/no-go: if combined p95 > 150 ms, invoke the fallback ladder (drop MediaPipe Face → Vision face-rect; or lower input resolution) and record the chosen cadence before M2-3 starts.

---

## M2-1 — Presence gate + landmark cadence controller
**Size**: M · **Deps**: M1-8 (SceneGate) · M2-0
The gating layer that authorizes the expensive models — protects battery and enforces the ≤5 fps settled-only cadence.
**Acceptance criteria**
- [ ] Cheap presence check (`VNDetectHumanRectanglesRequest`) emits person-present yes/no with the dominant subject's rect.
- [ ] Landmark models (body/hand/face) run **only** when presence is true **and** the frame is settled (`SceneGate`) **and** the ≤5 fps cadence cap allows it — all three gates required.
- [ ] Cadence cap is a named constant; raising it (GREEN path) is a one-line change, not a refactor.
- [ ] Runs off the camera queue with the existing drop-if-busy backpressure — Tier-0 loop FPS is never reduced by landmark work (verify via M0-4: Tier-0 FPS ≥ 25 with the gate active).

---

## M2-2 — Confidence gating + temporal smoothing  ⚠ HARD REQUIREMENT
**Size**: M · **Deps**: M2-0
The trust layer. Directly mitigates the "false cue erodes trust" risk — the zero-false-cue KPI lives or dies here.
**Acceptance criteria**
- [ ] Per-keypoint confidence floor (named constant); keypoints below it are discarded, not guessed.
- [ ] Temporal smoothing over a short rolling window so a single flickering keypoint can't fire a signal (documented window size + method).
- [ ] A signal is emitted only when its supporting keypoints are stable across N frames; transient detections are suppressed.
- [ ] Pure, unit-tested in isolation with synthetic keypoint streams (stable → emits; flickering → suppressed; low-confidence → suppressed).

---

## M2-3 — Body-pose signals: awkward crop + headroom (Vision)
**Size**: M · **Deps**: M2-1, M2-2
`VNDetectHumanBodyPoseRequest` skeleton → boundary geometry. Writes into `BodySignal`.
**Acceptance criteria**
- [ ] Awkward-crop: a skeletal joint (wrist/elbow/ankle/knee) or head crown intersecting a frame boundary emits a crop hint; a "clean" crossing (e.g. mid-torso) does not.
- [ ] Headroom: derived from head-top keypoint vs. frame top → nudgeUp/nudgeDown, using the same UIKit convention as M1 framing.
- [ ] All geometry runs through the M2-0 coordinate helper and the M2-2 smoothing layer.
- [ ] Output written into `SignalFrame.body`; producer is pure (no speaking, no UI).

---

## M2-4 — Lens-obstruction signal (MediaPipe hand)
**Size**: M · **Deps**: M2-1, M2-2
MediaPipe Hand Landmarker (21-pt) → finger-cluster-over-edge detection. Highest-priority body signal.
**Acceptance criteria**
- [ ] A hand/finger keypoint cluster intersecting a frame edge with high confidence emits an obstruction hint.
- [ ] Distinguishes "hand near the edge of the shot" (fine) from "hand occluding the lens" (fires) — documented heuristic.
- [ ] Clears within one cadence cycle once the obstruction leaves.
- [ ] Output written into `SignalFrame.body`; producer is pure.

---

## M2-5 — Gaze / face-yaw signal (MediaPipe face)
**Size**: M · **Deps**: M2-1, M2-2
MediaPipe Face Landmarker (mesh + transform) → head yaw/pitch. Writes into `BodySignal`.
**Acceptance criteria**
- [ ] Face yaw beyond a threshold (subject turned away) emits a gaze hint; threshold is a named constant.
- [ ] Suppressed when face confidence is low or a deliberate profile is plausible (documented heuristic) — feeds the false-cue KPI.
- [ ] Output written into `SignalFrame.body`; producer is pure.

---

## M2-6 — Cue-engine wiring + edge behavior
**Size**: M · **Deps**: M2-3, M2-4, M2-5
Route `BodySignal` into the existing engine at the reserved `.body` priority; obstruction escalated above `.stability`.
**Acceptance criteria**
- [ ] `CueEvaluator` maps `BodySignal` → cues: obstruction **above** `.stability`; crop/headroom/gaze at `.body` (above `.composition`). Existing debounce/cadence/hysteresis unchanged.
- [ ] New `CueText` strings for obstruction / crop / gaze / body-headroom.
- [ ] **No-person fallback**: with presence false, no body cues fire; Tier-0 (M1) cues continue unchanged.
- [ ] **Multi-person**: signals computed against the dominant subject (largest/most central) with a documented tie-break.
- [ ] Guides overlay optionally reflects the active body signal (reuse `GuidesOverlayView`); voice unchanged.

---

## M2-7 — Integration & validation
**Size**: M · **Deps**: M2-6
No new signals — wire everything, run the fault-injection walkthrough, verify the KPIs.
**Acceptance criteria**
- [ ] End-to-end on-device: each of the four faults (obstruction / crop / gaze / bad headroom), deliberately induced with a person in frame, produces the correct prioritized cue within the cadence budget.
- [ ] **Zero-false-cue KPI**: a person-free scene and a low-confidence/low-light scene each produce **no** body cues over a sustained run.
- [ ] 3–5 min person-shooting session stays within the M0-4 thermal budget (no throttle; Tier-0 FPS ≥ 25) with both model paths active.
- [ ] Integration tests (Swift Testing) for the `BodySignal` → cue path, mirroring `IntegrationLatencyTests`; demo-script section added for the four body scenarios.

**M2 exit**: body-aware cues correct in real time with a person present; silent and trustworthy when not. Ready to split toward M3 (VLM) — independent, deferred to a high-level eval.

---

## Out of scope (M2)
- **Gesture detection** (thumbs-up / open-palm triggers) — Phase 2; flag if it threatens the timeline.
- **VLM / aesthetic judgment** — M3.
- Emotion/expression reading, identity, group-headroom, subject-switching UX.

## Dependency graph
```
M2-0 (MediaPipe spike + coord layer) ──┬──────────────┐
M2-1 (presence gate + cadence) ────────┤              │
M2-2 (confidence + smoothing) ─────────┴─┬─> M2-3 ────┤
                                         ├─> M2-4 ────┼─> M2-6 ──> M2-7
                                         └─> M2-5 ────┘
```
M2-0, M2-1, M2-2 are the foundation; the three signal tickets (M2-3/4/5) are parallelizable once they land; M2-6 wires them; M2-7 validates.
