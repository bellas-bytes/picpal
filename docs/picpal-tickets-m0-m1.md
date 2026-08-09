# PicPal — M0 & M1 Tickets

**Companion to**: [picpal-build-order.md](picpal-build-order.md), [picpal-prd.md](picpal-prd.md)
**Date**: 2026-08-09
**Platform**: iOS (Swift, AVFoundation, Vision, CoreMotion, AVSpeechSynthesizer)
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

Conventions: every signal ticket outputs into a shared `SignalFrame` value type (immutable snapshot per analyzed frame); the cue engine consumes `SignalFrame`s. Keep signal producers pure and side-effect free — they compute, they don't speak.

---

## M0 — Foundations & de-risking spikes

### M0-1 — Camera capture pipeline
**Size**: M · **Deps**: none
Set up AVFoundation capture with controlled resolution and frame rate, exposing frames to the analysis layer.
**Acceptance criteria**
- [ ] `AVCaptureSession` streams `CVPixelBuffer` frames via a delegate at a configurable target FPS and resolution.
- [ ] Resolution/FPS are settable at runtime (needed to tune perf in M0-5).
- [ ] Frames are delivered on a dedicated queue without blocking the UI thread.
- [ ] Camera permission flow handled; graceful state when denied.

### M0-2 — Live camera view + debug overlay scaffold
**Size**: S · **Deps**: M0-1
A full-screen camera preview with a developer overlay for raw values (no coaching yet).
**Acceptance criteria**
- [ ] Live preview renders the capture feed full-screen.
- [ ] A toggleable debug overlay shows placeholder numeric fields (tilt°, blur score, exposure, FPS, thermal state).
- [ ] Overlay is a reusable layer later tiers can draw into.

### M0-3 — Device motion + motion-settle detector
**Size**: M · **Deps**: none (parallel with M0-1)
CoreMotion-based orientation plus a "user is composing" stability signal.
**Acceptance criteria**
- [ ] Device roll/pitch available as a smoothed stream (for tilt in M1-1).
- [ ] `isSettled` boolean emitted when motion stays below a threshold for a configurable window (default ~300–500ms).
- [ ] `isSettled` transitions are debounced (no rapid true/false flapping while hand-holding).
- [ ] Threshold + window are configurable constants (no magic numbers inline).

### M0-4 — Perf & thermal telemetry harness
**Size**: M · **Deps**: M0-1 · **Risk-critical**
Instrumentation that stays in for the whole project — the early-warning system for the battery/thermal risk.
**Acceptance criteria**
- [ ] Per-frame processing time and dropped-frame count measured and surfaced in the debug overlay.
- [ ] `ProcessInfo.thermalState` logged and displayed; transitions (nominal→fair→serious) timestamped.
- [ ] Battery level sampled at session start/end to estimate drain over a 3–5 min run.
- [ ] Timings exportable (log file or console dump) for comparing milestones.

### M0-5 — Landmark latency spike (Vision pose/hand/face)  ⚠ GATE
**Size**: L · **Deps**: M0-1, M0-4 · **Risk-critical / critical-path gate**
Prove Apple Vision landmarks are fast and cool enough to build M2 on. This ticket produces a **go/no-go decision**, not shippable UI.
**Acceptance criteria**
- [ ] Vision pose, hand, and face-mesh requests run against the live feed on a target mid-tier device.
- [ ] Per-model and combined inference time measured via M0-4; result recorded against the **<150ms** cue budget.
- [ ] Sustained-load test: 3–5 min continuous run with thermal + FPS captured; documents whether frame rate holds.
- [ ] Written **go/no-go** with a fallback strategy if it fails (e.g., lower landmark resolution, run landmarks at reduced cadence vs. every frame, or run only when settled).
- [ ] Decision recorded in the doc/PR so M2 planning uses real numbers, not assumptions.

**M0 exit**: capture + motion + telemetry working on-device, and a data-backed go/no-go on landmark latency.

---

## M1 — Tier 0 real-time loop (the spine)

> Target for the whole milestone: on a stable frame, a correct, prioritized spoken + visual cue within **<150ms**, and silence when the frame is good. Useful with the VLM off.

### M1-1 — Tilt signal
**Size**: S · **Deps**: M0-3
**Acceptance criteria**
- [ ] Produces a signed tilt angle from CoreMotion roll (optionally cross-checked with horizon edge detection).
- [ ] Emits a `level`/`tilted` state with a configurable dead-zone (e.g., ±2° reads as level) and hysteresis so it doesn't oscillate at the boundary.
- [ ] Output written into `SignalFrame`.

### M1-2 — Blur / shake signal
**Size**: M · **Deps**: M0-1
**Acceptance criteria**
- [ ] Laplacian-variance sharpness score computed per analyzed frame.
- [ ] Threshold classifies `sharp`/`blurry`; validated against a few real handheld-shake clips.
- [ ] Uses a downscaled frame if needed to stay within the per-frame time budget (verify via M0-4).
- [ ] Output written into `SignalFrame`.

### M1-3 — Exposure / clipping signal
**Size**: S · **Deps**: M0-1
**Acceptance criteria**
- [ ] Luminance histogram computed; `%` of clipped highlights and crushed shadows derived.
- [ ] Emits `underexposed`/`ok`/`overexposed` with configurable thresholds.
- [ ] Output written into `SignalFrame`.

### M1-4 — Framing signal (saliency vs. thirds)
**Size**: M · **Deps**: M0-1
**Acceptance criteria**
- [ ] Vision saliency (attention-based) yields a primary-subject box.
- [ ] Computes centering vs. rule-of-thirds intersections and vertical headroom.
- [ ] Emits directional hints (`nudge-left/right/up/down`, `too-centered`) with dead-zones.
- [ ] Degrades to "no clear subject" cleanly (no false hints) — sets up M2's person-specific version.
- [ ] Output written into `SignalFrame`.

### M1-5 — Cue engine  ★ reused by M2 & M3
**Size**: L · **Deps**: M1-1..M1-4
The heart of the loop; all tiers emit into it. Build it well — M2/M3 depend on it unchanged.
**Acceptance criteria**
- [ ] Consumes a `SignalFrame` and selects **at most one** cue per tick by a defined priority order (per PRD: safety/obstruction → stability → exposure → subject/body → composition → aesthetic). M1 wires the tiers it has; obstruction/body slots reserved for M2.
- [ ] Debounce + cadence cap: no more than the configured cues-per-window; a just-spoken cue won't immediately repeat.
- [ ] Hysteresis: a cue clears only after the signal is comfortably back in the good zone (no on/off flicker).
- [ ] Emits a structured `Cue` (text + priority + source tier) — rendering/voice are separate concerns.
- [ ] Unit-tested against synthetic `SignalFrame` sequences (flapping input → stable single cue; good frame → no cue).

### M1-6 — Visual guides overlay
**Size**: M · **Deps**: M0-2, M1-1, M1-4
**Acceptance criteria**
- [ ] Live level line reflecting M1-1; snaps/turns green within the level dead-zone.
- [ ] Rule-of-thirds grid; subject box from M1-4 shown in debug.
- [ ] "Good state → green" visual language consistent across guides.
- [ ] Overlay updates within the frame budget without dropping preview FPS (verify via M0-4).

### M1-7 — Voice output (TTS + pacing)
**Size**: M · **Deps**: M1-5
**Acceptance criteria**
- [ ] `AVSpeechSynthesizer` speaks `Cue` text on-device.
- [ ] Pacing respects the cue-engine cadence cap; a new higher-priority cue can interrupt, equal/lower priority cannot.
- [ ] Warm-but-terse phrasing map for each cue type (action-first; warmth sparing).
- [ ] Mute / on-device-only friendly (voice can be disabled without breaking cues).

### M1-8 — Event-driven sampling + scene-change signature
**Size**: M · **Deps**: M0-3, M1-2..M1-4
Gates expensive work to stable, novel frames — and produces the signature M3 will use for stale-suppression.
**Acceptance criteria**
- [ ] Heavy analysis escalates only when `isSettled` (M0-3) is true.
- [ ] A cheap per-frame **scene-change signature** (e.g., low-res hash / histogram + saliency-box delta) flags "materially changed since last analyzed frame."
- [ ] Signature is exposed for later VLM gating (M3) — designed now, even though the VLM isn't built yet.
- [ ] Verified to cut redundant analysis on a static scene (measurable drop in heavy-path invocations via M0-4).

### M1-9 — Integration & demo build
**Size**: M · **Deps**: M1-5..M1-8
**Acceptance criteria**
- [ ] End-to-end: point at a scene → stable frame → correct prioritized spoken + visual cue within <150ms; good frame → silence.
- [ ] Runs a 3–5 min session within the M0-4 thermal/FPS budget.
- [ ] **VLM entirely absent** and the app is still useful (the Phase-1 spine bar).
- [ ] Short demo script covering tilt, blur, exposure, and framing cues.

**M1 exit**: a useful, real-time-feeling, VLM-free coaching app on device, built on a cue engine and scene-change signature that M2 and M3 plug into unchanged.

---

## Suggested order & parallelization
- **M0**: M0-1 and M0-3 in parallel → M0-2 + M0-4 → **M0-5 (gate)**.
- **M1**: signals M1-1..M1-4 parallelize once M0 lands → **M1-5 cue engine** (the join point) → M1-6/M1-7/M1-8 parallel → M1-9.
- Do **not** start M2/M3 planning in earnest until **M0-5** returns go.
