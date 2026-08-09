# PicPal — Phase 1 Build Order

**Companion to**: [picpal-prd.md](picpal-prd.md) (v1.1)
**Date**: 2026-08-09
**Scope**: iOS prototype. Tier 0 (raw-pixel CV) + Tier 0.5 (Apple Vision landmarks) + Tier 2 (async cloud VLM).

## Sequencing principles

1. **Tier 0 is the spine.** The app must be genuinely useful with the VLM off. Build the on-device real-time loop first; the VLM is the *last* thing added, not the first.
2. **Front-load risk.** The two things most likely to kill the prototype — sustained battery/thermal cost of running CV + landmarks every frame, and whether landmark inference actually hits <150ms — are proven in M0 *before* you build features on top of them.
3. **Every milestone is a vertical slice.** Each one leaves a working, demoable app — never a half-wired pipeline.
4. **One cue engine, fed by tiers.** All tiers emit into a single priority-ordered cue engine; tiers are added as new signal sources, not new UIs.

## Dependency graph

```
M0 Foundations & spikes ──┬──> M1 Tier 0 loop ──┬──> M2 Tier 0.5 landmarks ──┐
   (camera, motion,       │                     │                            ├──> M4 Tune & validate
    perf harness,         │                     └──> M3 Tier 2 VLM ──────────┘
    landmark spike)       │
                          └── (cue engine + voice + guides scaffold built in M1, reused by M2/M3)
```

M2 and M3 both depend on M1 but are independent of each other — a small team can split them after M1 lands.

---

## M0 — Foundations & de-risking spikes
**Goal**: Prove the platform can sustain the pipeline, and stand up the plumbing everything else needs.
**Exit criteria**: A build that captures frames, reads device motion, and reports live latency + thermal telemetry on a real mid-tier device — plus a go/no-go answer on landmark latency.

- Camera capture pipeline (AVFoundation): controlled resolution + frame rate, frame buffer access.
- Device motion (CoreMotion): orientation/tilt + a **motion-settle detector** (stability threshold).
- **Perf/thermal harness** (top risk): instrument per-frame processing time, dropped frames, `ProcessInfo.thermalState`, and battery drain over a 3–5 min session. This telemetry stays in for the whole project.
- **Landmark latency spike** (top risk): run Apple Vision pose/hand/face on the live feed, measure inference ms + thermal impact. Validate <150ms per cue and sustained frame rate. *If this fails, adjust cadence/resolution strategy now, before M2.*
- App skeleton: live camera view, a debug overlay for raw signal values.

---

## M1 — Tier 0 real-time loop (the spine)
**Goal**: A useful coaching app driven entirely by raw-pixel CV, **VLM off**.
**Exit criteria**: On a stable frame, the app delivers a correct, prioritized spoken + visual cue within <150ms for tilt / blur / exposure / framing, and stays quiet when the frame is good.

- Signal computations (raw-pixel + motion):
  - Tilt (CoreMotion + edge/horizon detection)
  - Blur / shake (Laplacian variance)
  - Exposure / clipping (histogram)
  - Rough framing (Vision saliency box vs. thirds grid; centering + headroom)
- **Cue engine** (reused by all later tiers): priority ordering, one-cue-at-a-time, debounce + cadence cap, hysteresis so cues don't flicker on/off at thresholds.
- Visual guides overlay: live level line, thirds grid, "good state → green."
- Voice output: on-device TTS with pacing that respects the cadence cap.
- Event-driven sampling: motion-settle + a cheap **scene-change signature** (used later to gate the VLM).

---

## M2 — Tier 0.5 semantic landmarks (the v1.1 differentiator)
**Goal**: Body-aware coaching — the "photograph a person" moment — on-device, no VLM.
**Exit criteria**: With a person in frame, the app correctly catches lens obstruction, awkward crops, gaze-away, and headroom in real time, and produces **no false body cues** when no person is present or confidence is low.

- Integrate Vision pose / hand / face-mesh into the M0 pipeline.
- **Confidence gating + temporal smoothing** of keypoints (directly mitigates the "false cue erodes trust" risk — treat as hard requirement).
- **Presence gating**: only run landmark models when a person/hands are plausibly present (protects battery — ties back to M0 telemetry).
- Signal geometry:
  - Lens obstruction (hand/finger cluster over frame edge) → **highest priority cue**
  - Awkward crop (limb/head intersecting frame boundary at a bad joint)
  - Gaze / face-yaw (subject turned away when a to-camera shot is intended)
  - Person-specific headroom / thirds placement
- Feed into the cue engine at the right priority (obstruction above stability; body positioning above composition).
- Gesture detection — **nice-to-have, flag if it threatens the timeline.**
- Edge behavior: graceful no-person fallback (→ M1 only), basic multi-person (coach dominant subject), low-light confidence gating.

---

## M3 — Tier 2 VLM (async taste; never in the critical path)
**Goal**: Periodic aesthetic / candid-moment coaching that layers on without ever blocking the loop.
**Exit criteria**: VLM cues appear only on stable, novel frames, never delay Tier 0/0.5, and are silently dropped when the moment has passed. App remains fully functional with the VLM offline.

- Thin **VLM proxy service**: API keys off-device, cost controls, request cancellation.
- VLM client: fired on **settle-events only** (motion-settle + scene changed), cadence capped (~1 call / 2–4s).
- **Stale-suppression**: tag each call with the frame's CV/landmark signature; discard the response if the scene has materially changed.
- Merge VLM output into the cue engine at **lowest priority**.
- Offline / unavailable degradation: quiet, non-alarming; Tier 0/0.5 continue untouched.
- On-device-only mode toggle (VLM off) — also a privacy setting.

---

## M4 — Integration, tuning & validation
**Goal**: Hit the KPIs, not just the features.
**Exit criteria**: Moderated sessions run; the primary KPI ("feels real-time," ≥70%) and non-annoyance band (~1–3 cues/episode) are measurable and met, or you have the data to iterate.

- Tune cue priority, cadence, and hysteresis against the **non-annoyance** target (chattiness is a failure mode).
- KPI telemetry: post-session "felt real-time?" prompt; actionable-latency timing (stable frame → first cue); cue-count distribution; person-shot flag.
- Build the validation session kit: scene tasks **+ an explicit "photograph a person" task set**.
- Final pass on privacy copy (what leaves the device, on-device-only mode).

---

## Notes for a small team
- **After M1, split M2 and M3** across two people — they share the cue engine and signature but are otherwise independent.
- **Keep the M0 perf/thermal telemetry on permanently.** Battery/thermal is the risk most likely to surface late; watch it every milestone, especially when M2 adds a second per-frame model.
- **Don't polish the VLM prompt early.** Get the loop feeling real-time first (M1–M2); the VLM is upside, and over-investing in it before the spine feels good is the classic trap for this product.
