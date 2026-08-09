# Product Requirements Document: PicPal — Real-Time Photo Framing Coach

**Version**: 1.1
**Date**: 2026-08-09
**Author**: Sarah (Product Owner)
**Quality Score**: 93/100

> **Changelog v1.1**: Added a **semantic landmark tier (Tier 0.5)** — on-device pose/hand/face keypoints — between raw-pixel CV and the cloud VLM. Promoted subject-facing coaching ("photograph a person") from a v2 secondary persona to a **v1 co-primary focus**. Landmark engine is **Apple Vision** for the iOS prototype; MediaPipe is the cross-platform path adopted when Android work begins.

---

## Executive Summary

PicPal is a mobile app that acts like a friendly photographer standing next to you, giving real-time verbal coaching while you frame a shot — "tilt up a touch," "your thumb's over the lens," "have them look back at you," "nice light, hold." It targets casual phone photographers who feel their photos come out "meh" and want better results *in the moment*, without learning photography — including the very common, high-emotion moment of **taking a photo of another person**.

The entire product hinges on **latency**: coaching only feels like coaching if feedback arrives fast enough to act on before the moment passes. PicPal solves this by treating latency as a routing problem across a **tiered analysis stack**, where each coaching signal is produced by the cheapest tier that can compute it:

- **Tier 0 — raw-pixel CV (on-device, every frame):** tilt, blur, exposure, saliency-based framing.
- **Tier 0.5 — semantic landmarks (on-device, real-time):** pose, hand, and face keypoints — "hand covering lens," "subject's face turned away," "arm cropped awkwardly," "hand gesture detected." Structured meaning about bodies, no VLM call.
- **Tier 2 — frontier VLM (cloud, async):** fuzzy aesthetic taste — "this feels like a candid, joyful moment," "the composition is a bit static."

Landmarks are the key v1.1 insight: a huge fraction of what makes a photo *of a person* good or bad is body positioning, and that's pure keypoint geometry — instant, on-device, VLM-free. The VLM stays out of the real-time critical path entirely, called only periodically for aesthetic judgment.

Success for the first prototype is defined narrowly: **does the coaching feel real-time?** If casual users report feedback arrives in time to act on, the core bet is validated and everything else is upside.

---

## Problem Statement

**Current Situation**: Casual phone photographers take tilted, blurry, badly-lit, or awkwardly-framed photos and don't know why or how to fix them in the moment. This is worst when photographing *another person*: cropped limbs, subjects looking the wrong way, a thumb over the lens, heads cut off — all invisible to the shooter until it's too late. Existing tools help *after* capture or are passive (a static grid).

**Proposed Solution**: A live camera experience that continuously analyzes framing **and body positioning**, delivering warm spoken coaching in real time plus lightweight on-screen guides. It fixes the basics instantly (tilt, blur, exposure, composition), catches body/subject problems instantly via landmarks (lens obstruction, awkward crops, gaze direction, gestures), and layers in VLM aesthetic judgment when it has something worth saying.

**Business Impact**: Turns "I wish my photos looked better" into "my photos look better" without a learning curve — and specifically nails the emotionally-charged "take a good photo of me / of us" moment, which is more differentiated and more shareable than generic scene coaching.

---

## Success Metrics

**Primary KPI (the prototype's reason to exist):**
- **Perceived real-time responsiveness**: ≥70% of test users agree "the feedback came fast enough to act on it before the shot changed." Measured via post-session prompt + telemetry (time from stable frame → first actionable cue).

**Supporting KPIs:**
- **Actionable latency (technical)**: Tier-0 / Tier-0.5 cue delivered within **<150ms** of a stable frame; VLM "taste" cue within **<3s**, suppressed if the scene has already changed.
- **Coaching usefulness**: ≥60% of users self-report the coached photo is "better than I'd have taken on my own" (blind A/B where feasible).
- **Person-shot quality (new)**: For photos of a person, ≥60% of subjects/shooters prefer the coached shot in a blind comparison.
- **Non-annoyance**: Median coaching cues per stable framing episode stays ~1–3, not a stream.

**Validation**: Moderated sessions with 8–15 casual photographers across scenes (indoor, outdoor, low-light) and an explicit **"photograph a person"** task set, plus in-app telemetry.

---

## User Personas

### Co-Primary A: "Casual Cam" — the everyday phone photographer
- **Role**: Non-photographer shooting food, travel, pets, scenes, moments.
- **Goals**: A noticeably better shot right now, zero effort or learning.
- **Pain Points**: Tilted/blurry/awkwardly framed photos; no vocabulary or rules; editing can't fix bad framing.
- **Technical Level**: Novice; zero tolerance for setup, jargon, or latency.

### Co-Primary B: "Sharing Sam" — shooting a photo *of another person*  *(promoted to v1)*
- **Role**: Friend/partner handed a phone to "take a photo of me / of us."
- **Goals**: Not embarrass themselves — get a shot the subject actually likes, without knowing how to pose or frame people.
- **Pain Points**: Cuts off feet/heads, subject looks away or is mid-blink, own thumb over the lens, awkward limb crops — all noticed only after the moment's gone.
- **Technical Level**: Novice. High emotional stakes ("don't ruin my photo").

---

## Coaching Experience Principles

**Voice**: Warm coach / friend — encouraging and conversational, not a robotic instructor.

**Critical tension**: A warm, chatty voice fights the real-time feel if it talks too much. **Responsiveness beats personality.** Rules:
- Cues are short and action-first ("Level it out," "Thumb's on the lens"); warmth is added sparingly.
- Never stack cues — one thing at a time, prioritized: **safety/obstruction (lens covered) → stability → exposure → subject/body positioning → composition → aesthetic (VLM)**.
- VLM remarks fire only on stable, novel frames and are dropped silently if the moment has passed.
- Voice cadence is capped — a calm friend, never a nagging stream.

---

## User Stories & Acceptance Criteria

### Story 1: Instant basic coaching (Tier 0, raw-pixel CV)
**As a** casual photographer **I want** immediate feedback on tilt, blur, exposure, and framing **so that** I can fix the obvious problems before I shoot.
- [ ] Level/tilt cue within <150ms of the phone settling (device motion + edge detection).
- [ ] Shake/blur detected (Laplacian variance) → "hold steady."
- [ ] Over/under-exposure and clipping detected via histogram.
- [ ] Rough framing (saliency box vs. thirds grid) nudges off dead-center.
- [ ] On-screen guides (level line, thirds grid) update live and turn green when good.
- [ ] **Works with the VLM disabled or offline.**

### Story 2: Body & subject coaching (Tier 0.5, on-device landmarks)  *(new in v1.1)*
**As a** person photographing someone **I want** instant feedback on body positioning and lens obstruction **so that** I don't ruin the shot in ways I can't see in the moment.
- [ ] **Lens obstruction**: a hand/finger landmark cluster near the lens or covering the frame edge → high-priority "thumb's on the lens" cue within <150ms.
- [ ] **Awkward crop**: pose landmarks show a limb/head intersecting the frame boundary at a bad joint (wrist, ankle, neck) → "you're cropping their feet — tilt down."
- [ ] **Gaze/face direction**: face-mesh yaw shows the subject turned away when a to-camera shot is intended → "have them look back at you."
- [ ] **Headroom/placement**: face/pose position vs. frame → headroom and rule-of-thirds cues specific to the person.
- [ ] **Gesture detection** (nice-to-have): recognized hand gestures (wave, peace, thumbs-up) can trigger a "capture-worthy moment" hint.
- [ ] All landmark cues run on-device in real time; **no VLM call** for any body-positioning signal.
- [ ] Degrades cleanly when no person is present (falls back to Story 1 only — no false body cues).

### Story 3: Aesthetic "taste" coaching (Tier 2, cloud VLM, async)
**As a** casual photographer **I want** occasional smarter suggestions ("candid, joyful — hold this," "too much empty sky") **so that** composition improves beyond mechanics.
- [ ] VLM called only on a *settle event*: motion below threshold AND scene materially changed since last call.
- [ ] VLM never blocks the real-time loop; Tier 0/0.5 continue regardless of VLM state.
- [ ] Each VLM call tagged with the frame's CV/landmark signature; response discarded silently if the scene changed (stale-suppression).
- [ ] VLM cadence capped (≈ one call per 2–4s max).

### Story 4: Feels real-time (perceived latency)
**As a** casual photographer **I want** the app to always feel responsive **so that** coaching arrives in time to act.
- [ ] There is always an instant visual/verbal signal from Tier 0/0.5 while slower analysis is pending.
- [ ] No cue references a frame the user has already moved past.
- [ ] Voice pacing feels like a calm human coach.

### Story 5: Graceful edges
- [ ] No person / no clear subject → coaching falls back to horizon/exposure/framing only, no false body cues.
- [ ] Very low light → prioritize stability + exposure; suppress fine composition nitpicks; landmark confidence gated so low-confidence keypoints don't fire cues.
- [ ] Multiple people → coach on the dominant/nearest subject; avoid conflicting per-person cues.
- [ ] Offline / VLM unavailable → full Tier 0 + Tier 0.5 experience with quiet degradation.

---

## Functional Requirements

### Core architecture: the latency tier stack
- **Tier 0 — Raw-pixel CV, on-device, ~every frame (5–30ms)**: tilt, blur, exposure/clipping, saliency framing. (Apple Vision / Core Image; device motion.)
- **Tier 0.5 — Semantic landmarks, on-device, real-time (~10–30ms)**: pose, hand, and face-mesh keypoints → lens obstruction, awkward crops, gaze direction, headroom, gestures. Derived from keypoint geometry with simple thresholds; **no VLM**. *(Engine: Apple Vision for the iOS prototype; MediaPipe when Android begins.)*
- **Tier 2 — Frontier VLM, cloud, async, settle-events only (1–3s)**: aesthetic/candid-moment judgment. Always out of the critical path.
- **Sampling**: Event-driven (motion-settle + scene-change), not fixed-interval. Cheap tiers run continuously; the VLM escalates only on stable, novel frames.
- **Perceived-latency UX**: instant Tier 0/0.5 feedback, progressive disclosure, stale-suppression, capped voice cadence, priority-ordered cues.

### Out of Scope (v1 prototype)
- MediaPipe integration (deferred to Android work; iOS uses Apple Vision).
- Distilled/fine-tuned on-device aesthetics model (Tier 1 "composition score").
- Scene-descriptor caching to reduce VLM spend.
- Predictive/temporal coaching ("light's improving, wait 2s").
- Multi-person group choreography ("everyone shuffle in").
- Fine-tuning a custom VLM; post-capture editing, filters, sharing, accounts, cloud storage.
- Android (iOS-only prototype).

---

## Technical Constraints

### Performance
- Tier 0 / Tier 0.5 cue: **<150ms** from stable frame; combined on-device pipeline must sustain live frame rate on a mid-tier device without thermal/battery collapse over a multi-minute session.
- VLM cue: **<3s**, async, stale-suppressed.
- Landmark models gated by confidence + run only when a person/hands are plausibly present, to protect battery.

### Security & Privacy
- Camera frames are sensitive; landmark analysis is **fully on-device** (a privacy win — body/face data never leaves the phone). Send frames to the cloud VLM only on settle-events, at minimized resolution.
- Face-mesh data stays on-device and is never persisted or transmitted.
- No account or PII for the prototype. Never place image data or personal info in URLs. Provide an "on-device only" mode (Tier 0 + 0.5, VLM off).

### Integration
- **Camera/CV/landmarks**: native camera pipeline + Apple Vision (image analysis + body/hand/face pose) + device motion. OpenCV only if a specific signal needs it.
- **VLM**: one hosted frontier vision API behind a swappable abstraction. When building against Claude, default to the latest capable model.
- **Voice**: on-device TTS for low-latency spoken coaching.

### Technology Stack (prototype)
- **Platform**: iOS first (native Vision landmarks + tight camera/TTS integration keep a small team fast). Android is a fast-follow.
- **On-device**: Swift + AVFoundation + Vision (pose/hand/face) + Core Image.
- **Cloud**: thin VLM proxy (keys off-device, prompt iteration, cost control, stale-request cancellation).
- **Cross-platform note**: adopt **MediaPipe** for landmarks when Android work starts, to share one landmark integration across platforms.

---

## MVP Scope & Phasing

### Phase 1: MVP prototype (proves "does it feel real-time?")
- Full **Tier 0** raw-pixel coaching (tilt, blur, exposure, framing) + live visual guides + warm voice.
- Full **Tier 0.5** landmark coaching via Apple Vision: lens obstruction, awkward crops, gaze direction, headroom (gesture detection nice-to-have).
- **Subject-facing "photograph a person" is a v1 focus** (Persona: Sharing Sam).
- Event-driven sampling; one hosted frontier **VLM** async on settle-events with stale-suppression + capped cadence — no fine-tuning, no on-device VLM.
- Graceful edges (no person / low light / multi-person basic / offline).
- iOS only.

**MVP Definition**: An iOS app that gives useful, real-time-*feeling* framing **and body-positioning** coaching — including a good photo of a person — that works even with the VLM off.

### Phase 2: Enhancements (once the feel is proven)
- MediaPipe landmarks + Android.
- Tier-1 distilled on-device aesthetics model (composition trend).
- Scene-descriptor caching to cut VLM cost/latency.
- Predictive coaching; multi-person group choreography; adaptive coaching depth by skill.

### Future Considerations
- Custom fine-tuned VLM once valuable coaching patterns are known.
- Accessibility-first voice mode for low-vision users.

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| VLM latency breaks the real-time feel | High | High | VLM never in critical path; Tiers 0/0.5 own the loop and work VLM-off; stale-suppression |
| Warm voice becomes chatty/annoying | Med | High | One cue at a time, priority-ordered; capped cadence; action-first phrasing |
| Combined on-device pipeline (CV + landmarks) drains battery / overheats | Med → High | Med | Confidence-gated + presence-gated landmark runs; event-driven escalation; perf budget on mid-tier device |
| False/low-confidence landmark cues ("crop" when confidence is poor) erode trust | Med | High | Confidence thresholds, temporal smoothing of keypoints, suppress cues below threshold |
| Person-focus widens scope and slows the prototype | Med | Med | Keep gesture detection nice-to-have; multi-person choreography deferred to v2 |
| Coaching is fast but not actually useful | Med | High | Validate usefulness + person-shot KPIs early in moderated sessions |
| VLM API cost scales badly | Med | Med | Settle-event gating now; scene-descriptor caching in v2 |

---

## Dependencies & Blockers

**Dependencies:**
- Apple Vision pose/hand/face capability on target iOS devices.
- Hosted frontier VLM API + thin proxy (keys, cost control, request cancellation).
- On-device TTS.

**Known Blockers:**
- VLM vendor choice (affects prompt design + latency) — pick one for the prototype; abstraction keeps it swappable.

---

## Appendix

### Glossary
- **VLM**: Vision-Language Model — analyzes an image and produces language reasoning about it.
- **Tier 0 / 0.5 / 2**: latency tiers — raw-pixel CV (instant) / semantic landmarks (instant, body-aware) / cloud VLM (slow, async, taste-only).
- **Landmark / keypoint**: an (x, y, confidence) point for a body joint, hand joint, or face-mesh vertex, from which positioning cues are computed with simple geometry.
- **Settle event**: motion below threshold *and* material scene change — the trigger for escalating to VLM analysis.
- **Stale-suppression**: discarding VLM advice whose frame the user has already moved past.
- **CV/landmark signature**: a cheap fingerprint of a frame used to detect material change and match async responses to the frame that produced them.

### References
- Architecture brainstorm (frame sampling, model size, on-device vs. cloud, hybrid CV/VLM, perceived latency, caching) and the v1.1 landmark-tier extension — captured in this session.

---

*This PRD was created through interactive requirements gathering with quality scoring to ensure comprehensive coverage of business, functional, UX, and technical dimensions.*
