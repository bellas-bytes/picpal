# Product Requirements Document: Body-Aware Coaching (M2 — Tier 0.5 Landmarks)

**Version**: 1.0
**Date**: 2026-08-11
**Author**: Sarah (Product Owner)
**Quality Score**: 93/100
**Companion to**: [picpal-prd.md](picpal-prd.md) · [picpal-build-order.md](picpal-build-order.md)

---

## Executive Summary

PicPal's Tier-0 loop (M0 + M1, shipped to `develop`) coaches on tilt, blur, exposure, and framing — but it is **subject-blind**. It can tell you the horizon is crooked; it cannot tell you your thumb is creeping over the lens, your subject's head is cropped at the chin, or they're looking away. For the single most common real-world shot — a photo of a person — the coaching is generic.

M2 adds **body awareness** — the "photograph a person" moment — using on-device landmark models, **no VLM**. Per the architecture decision on 2026-08-11, M2 ships on a **hybrid stack**: **Apple Vision** for presence and body pose, **MediaPipe** for detailed hand and face landmarks. New signals feed the *existing* cue engine at the reserved `.body` priority slot, producing specific, high-trust cues.

Because the hybrid stack runs a second per-frame model path — directly the battery/thermal risk M0 was built to watch — M2 is specified **defensively for the M0-5 "YELLOW" outcome**: landmark inference runs on **settled frames only, capped at ≤5 fps, behind a presence gate**. If on-device validation returns GREEN, cadence can be raised later; the spec never assumes it.

---

## Problem Statement

**Current Situation**: The app understands *image properties* (is it level, sharp, well-exposed, roughly composed) but nothing about *what is in the frame*. A casual user photographing a friend gets no help with the faults that actually ruin people-photos: obstructions, awkward crops, gaze-away, and bad headroom. These are invisible in the moment and only noticed later.

**Proposed Solution**: Compute body/hand/face keypoints on-device and derive four geometric signals — lens obstruction, awkward crop, gaze/face-yaw, and person-specific headroom — that emit into the cue engine at `.body` priority (obstruction escalated *above* stability; the rest above composition). The whole path is gated by confidence and temporal smoothing so a flickering keypoint never fires a false cue.

**Business Impact**: Delivers the **v1.1 differentiator**. Converts PicPal from "a spirit level with exposure warnings" into a coach that understands people — the capability that distinguishes it from every stock camera-guide feature.

---

## Success Metrics

**Primary KPIs:**
- **Fault-catch rate**: With a person in frame, ≥90% of deliberately-induced obstruction / crop / gaze / headroom faults produce the correct cue within the cadence budget.
- **False-cue rate (trust KPI — hard requirement)**: **Zero** false body cues when no person is present or when landmark confidence is below threshold. A single false "hand over lens" on an empty scene is a failure.
- **Thermal sustainability**: A 3–5 min continuous person-shooting session with both model paths active stays within the M0-4 budget — no thermal throttle, FPS ≥ 25 on the Tier-0 loop.

**Gate KPI (entry blocker):**
- Combined landmark **p95 < 150 ms** on a physical iPhone 17 (the M0-5 gate). See Dependencies.

**Validation**: Debug-overlay telemetry (Body / Hand / Face / VisionTotal rows already present) plus a scripted fault-injection walkthrough per signal.

---

## User Personas

### Primary: "Casual portrait-taker"
- **Role**: Shooting a friend or family member; not a photographer.
- **Goals**: A keeper photo of a person without post-hoc regret.
- **Pain Points**: Doesn't notice a cropped elbow, a thumb over the lens, or a subject looking away until the moment has passed.
- **Technical Level**: Novice.

### Secondary: "Self-shooter / propped phone"
- **Role**: The subject *is* the user, or a group with the phone propped/on a tripod.
- **Goals**: Good headroom and to-camera gaze when nobody is holding the phone to check the screen.
- **Pain Points**: Can't see the screen while framing — relies entirely on **spoken** cues.

---

## User Stories & Acceptance Criteria

### Story 1: Lens obstruction (highest priority)
**As a** casual portrait-taker **I want** to be told immediately when my hand or finger is over the lens **so that** I don't shoot a half-black frame.
- [ ] A hand/finger cluster intersecting a frame edge with high confidence emits an obstruction cue.
- [ ] Obstruction outranks **all** other cues, including stability (escalated above `.stability`).
- [ ] Clears within one cadence cycle once the obstruction is removed.

### Story 2: Awkward crop
**As a** casual portrait-taker **I want** to be warned when I've cut off a limb or the top of the head at a bad joint **so that** the framing looks intentional.
- [ ] A skeletal joint (wrist/elbow/ankle/knee) or the head crown intersecting the frame boundary emits a crop cue.
- [ ] No cue when the boundary crossing is at a "clean" point (e.g. mid-torso for a portrait crop).

### Story 3: Gaze / face-yaw
**As a** self-shooter **I want** to know when my subject is turned away from the camera **so that** I catch a to-camera shot when that's the intent.
- [ ] Face yaw beyond a threshold (subject turned away) emits a gaze cue.
- [ ] Suppressed when face confidence is low or the shot is plausibly a deliberate profile (documented heuristic).

### Story 4: Person-specific headroom
**As a** self-shooter **I want** headroom guidance based on the actual person **so that** they're placed well, not floating or crammed.
- [ ] Headroom derived from head-top keypoint vs. frame top emits nudge-up / nudge-down at `.body` priority (above composition).
- [ ] Falls back silently to M1 saliency framing when no person is detected.

### Story 5: No-person graceful fallback
**As a** user shooting a landscape **I want** the app to stay silent on body cues **so that** it isn't chattering about people who aren't there.
- [ ] With no person detected, **no** body cues fire; Tier-0 (M1) cues continue unchanged.

### Story 6: Multi-person — coach the dominant subject
- [ ] With multiple people, signals are computed against the **dominant** subject (largest / most central), documented tie-break.

### Story 7: Low-confidence / low-light suppression
- [ ] Below the confidence floor, all body signals are suppressed rather than guessed (feeds the false-cue KPI).

---

## Functional Requirements

### Hybrid stack — signal ownership

| Signal | Model | Rationale |
|---|---|---|
| **Presence gate** | Apple Vision (`VNDetectHumanRectanglesRequest`) | Cheap yes/no person-in-frame; gates the expensive models. |
| **Awkward crop, headroom** | Apple Vision (`VNDetectHumanBodyPoseRequest`) | Full skeleton → joint-vs-boundary geometry, head-top for headroom. |
| **Lens obstruction, (gesture: Phase 2)** | MediaPipe **Hand Landmarker** (21-pt) | Richer finger geometry than Vision hand pose for splayed-over-lens detection. |
| **Gaze / face-yaw** | MediaPipe **Face Landmarker** (mesh + transform) | Direct head yaw/pitch; more robust than Vision face-landmark yaw. |

### Core behaviors
- **Confidence gating + temporal smoothing** of every keypoint before any signal is derived — **hard requirement** (directly mitigates the false-cue trust risk).
- **Presence gating**: hand/face/body-pose models run **only** when the cheap presence gate says a person is plausibly present — protects battery.
- **Unified coordinate layer**: Vision (normalized, bottom-left origin) and MediaPipe (normalized, top-left origin) are converted through one tested helper to the app's UIKit top-left convention. (Mirrors the existing `visionRectToSwiftUI` pattern.)
- **Cue-engine wiring**: signals emit `Cue`s at `.body` priority; obstruction is escalated above `.stability`. Existing debounce / cadence / hysteresis apply unchanged.

### Out of Scope (M2)
- **Gesture detection** — nice-to-have; Phase 2, flag if it threatens timeline.
- **VLM / aesthetic judgment** — that's M3.
- Emotion/expression reading, identity, or any cloud call.

---

## Technical Constraints

### Performance & cadence (defensive — YELLOW assumption)
- Landmark models run on **settled frames only** (reuse `SceneGate` settle signal), **capped at ≤5 fps**, regardless of camera frame rate.
- Tier-0 (M1) loop is **never** blocked by landmark work — landmarks run off the camera queue with the existing drop-if-busy backpressure pattern.
- If on-device validation returns **GREEN (<50 ms p95)**, cadence may be raised to per-settled-frame in a follow-up; the default spec does not rely on it. If **RED (>150 ms)**, drop MediaPipe Face Landmarker first (fallback ladder from M0-5).

### Integration
- **MediaPipe Tasks Vision (iOS)** added as a dependency; `hand_landmarker.task` and `face_landmarker.task` bundled in-app. Models run in `.video` mode with monotonic timestamps.
- Integration path (CocoaPods vs. xcframework/SPM alongside current xcodegen setup) to be settled at ticket M2-0; treat as a spike.

### Platform / code standards (unchanged project constraints)
- Swift 6 strict concurrency (`@unchecked Sendable` + `OSAllocatedUnfairLock`; `nonisolated` delegate methods).
- **Swift Testing** only (`import Testing`), ≥80% coverage on new logic.
- 300-line file limit; no hardcoded magic numbers (named `static` constants); immutable value types for signal snapshots.
- Perf/thermal telemetry stays on permanently — watch it every ticket now that a second model path is live.

---

## MVP Scope & Phasing

### Phase 1 — M2 Core (required for v1.1)
1. MediaPipe integration spike + presence gate (Vision human-rectangles).
2. Body pose → awkward-crop + headroom signals.
3. Hand landmarker → lens-obstruction signal (escalated priority).
4. Face landmarker → gaze/face-yaw signal.
5. Confidence gating + temporal smoothing layer.
6. Cue-engine wiring at `.body`; no-person fallback; dominant-subject multi-person.
7. Integration + fault-injection validation; false-cue KPI verification.

**MVP Definition**: With a person in frame, the app catches obstruction, awkward crops, gaze-away, and headroom in real time — and produces **no false body cues** when no person is present or confidence is low.

### Phase 2 — Enhancements
- Gesture detection (thumbs-up / open-palm framing triggers).
- Refined multi-person (group headroom, subject switching).
- Cadence raise to per-settled-frame if device validated GREEN.

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Hybrid doubles per-frame model cost → thermal throttle | Med | High | Defensive ≤5 fps settled-only cadence + presence gate + permanent M0-4 telemetry; drop Face Landmarker if RED. |
| MediaPipe dependency/integration friction (CocoaPods vs SPM) | Med | Med | M2-0 integration spike before feature work; xcframework fallback. |
| False body cues erode trust | Med | High | Confidence gating + temporal smoothing as a **hard requirement**, verified by the zero-false-cue KPI. |
| M0-5 device gate returns RED | Low | Med | Fallback ladder already documented (lower res → drop face mesh → async offload). |
| Vision↔MediaPipe coordinate-system mismatch | Med | Med | Single tested conversion helper; unit tests mirroring `GuidesOverlayTests`. |

---

## Dependencies & Blockers

**Dependencies:**
- `VisionLandmarkProbe` (built, `isEnabled: false`) — enable + extend.
- `CuePriority.body` slot (reserved) — wiring target.
- `SceneGate` settle signal — cadence source.
- MediaPipe Tasks Vision iOS SDK + bundled `.task` models.

**Known Blockers:**
- **M0-5 on-device validation (HARD GATE)**: a 5-min sustained run on a physical iPhone 17 must confirm combined landmark **p95 < 150 ms** and stable thermal state **before M2 implementation begins**. Cannot be validated in the simulator/CI environment — requires manual device run. GREEN→raise cadence later; YELLOW→proceed as specified; RED→invoke fallback ladder at kickoff.

---

## M3 (Tier 2 VLM) — High-Level Evaluation *(not a full spec — deferred by decision)*

📊 **M3 Planning Readiness: 68/100.** Architecture is well-specified in the build order and the `SceneGate.lastProcessedSignature` stale-suppression hook already exists. It is **independent of M2** and should not be spec'd in detail until M2 direction is proven on-device.

**Open decisions before an M3 spec can be written:**
1. **Vendor / model** — which VLM, and hosted where (the "thin proxy service" keeps API keys off-device).
2. **Cost controls** — per-session call budget and cadence cap (~1 call / 2–4 s on settle-events only).
3. **Privacy copy** — explicit "what leaves the device" language + the on-device-only mode toggle (also a privacy setting).
4. **Degradation UX** — quiet, non-alarming behavior when the VLM is offline.

**Recommendation**: Park M3. Enter it only after M2's loop "feels real-time" on-device — over-investing in the VLM before the spine feels good is the classic trap for this product (build-order note). When ready, run `/product-requirements` for a dedicated M3 PRD.

---

## Appendix

### Glossary
- **Tier 0.5**: On-device Apple Vision / MediaPipe landmark models — between raw-pixel CV (Tier 0) and async cloud VLM (Tier 2).
- **Settled frame**: A frame passing `SceneGate`'s motion-settle + scene-change gate.
- **Presence gate**: Cheap person-in-frame check that authorizes the expensive landmark models.
- **`.body` priority**: Cue-engine slot (rawValue 3) reserved for M2 body signals.

### References
- [picpal-build-order.md](picpal-build-order.md) — M2/M3 milestone definitions.
- [m0-5-landmark-spike.md](m0-5-landmark-spike.md) — latency spike + pass/fail gate.
- `picpal/Sources/Landmarks/VisionLandmarkProbe.swift` — existing landmark scaffold.
- `picpal/Sources/CueEngine/Cue.swift` — `CuePriority.body` slot.

---

*Created through interactive requirements gathering. Architecture decisions (hybrid Vision+MediaPipe stack; defensive YELLOW cadence; M3 deferred to high-level eval) were confirmed with the product owner on 2026-08-11.*
