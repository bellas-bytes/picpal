# Product Requirements Document: PicPal — Phase 2 & Launch

**Version**: 1.0
**Date**: 2026-08-11
**Author**: Sarah (Product Owner)
**Quality Score**: 91/100
**Companion to**: [picpal-prd.md](picpal-prd.md) · [picpal-build-order.md](picpal-build-order.md)

---

## Executive Summary

PicPal's Phase 1 prototype (M0–M4) is built and merge-ready: a three-tier coaching stack (raw-pixel CV → landmark geometry → cloud VLM) that delivers real-time framing and body-positioning coaching on iOS. Phase 2 has three milestones before public launch.

**M5 — Scene-descriptor caching**: eliminates redundant VLM API calls on static or slowly-changing scenes, reducing cost and improving coaching consistency. Builds directly on the `SceneSignature` fingerprint already computed for stale-suppression.

**M6 — Predictive coaching + group-aware multi-person**: upgrades the coaching voice from reactive-only to situationally aware. Predictive hints ("light's getting better, hold a moment") replace premature corrective cues when a scene is actively improving. Group-aware cues ("someone's getting cut off on the right") handle the common case of 2–5 people in frame without per-person choreography complexity.

**M7 — TestFlight beta + App Store submission**: a structured beta phase followed by a free public launch. Success criterion: ≥70% of beta users agree the coaching feels real-time (the same KPI from M4), plus no regression in non-annoyance ratings.

---

## Problem Statement

**Current Situation (post-M4)**: The coaching pipeline is correct and latency-constrained. Three gaps remain before it's ready for strangers to use:
1. Every stable scene fires a VLM call even if the advice would be identical to the last call — costly at scale and occasionally inconsistent if the VLM varies its phrasing.
2. Coaching is purely reactive: when a scene is mid-improvement (phone tilting toward level, light getting better), the app still emits corrective cues instead of waiting, which feels robotic and slightly annoying.
3. Group shots — the "take a photo of all of us" moment — produce single-subject coaching that ignores people being cut off at the edges.

**Proposed Solution**: M5 adds an on-device response cache keyed on scene fingerprint. M6 adds a signal-trend layer that gates corrective cues when improvement is underway, and a group-presence detector that emits crowd-level framing cues. M7 puts the app in beta testers' hands before public release.

**Business Impact**: These three milestones complete the Phase 1 PRD's coaching experience and bring PicPal to App Store launch as a free, fully-functional product — no paywall, no signup, no server dependency for on-device-only mode.

---

## Success Metrics

**Carry-forward KPIs (must not regress from M4 baseline):**
- Perceived real-time responsiveness: ≥70% of users agree feedback came fast enough to act on.
- Non-annoyance: median coaching cues per stable episode ~1–3.
- Tier-0/0.5 actionable latency: <150ms from stable frame.

**New Phase 2 KPIs:**
- **VLM call reduction (M5)**: ≥50% reduction in VLM API calls on a 60-second static-or-slowly-changing scene vs. baseline (measured in the M7 beta via telemetry export).
- **Predictive hint accuracy (M6)**: when a predictive "wait" hint is emitted, the coached condition (tilt, light) improves to threshold within the wait window in ≥60% of cases (measured via settle-event telemetry).
- **Group-shot coverage (M6)**: in scenes with ≥2 detected people, ≥1 group-level cue is emitted when a person is being cropped — measured via moderated session task "take a group photo."
- **Beta exit criterion (M7)**: 0 crash reports on TestFlight builds across 3 consecutive days before App Store submission.

**Validation**: M7 TestFlight beta with 8–20 testers; explicit group-photo task set in moderated sessions; telemetry export reviewed post-session.

---

## User Personas

*(Carried forward from Phase 1 PRD — unchanged)*

### Co-Primary A: Casual Cam
- Shooting everyday scenes (food, travel, moments). Zero setup tolerance.

### Co-Primary B: Sharing Sam
- Handed a phone to "take a photo of me / of us." High emotional stakes — group shots are the new focus in Phase 2.

### New consideration: Beta Tester
- Slightly more technical than typical users; will report bugs via TestFlight feedback.
- Pain point: rough edges, inconsistent cues, confusing onboarding.
- Goal: confirm the coaching feels real-time before wider release.

---

## User Stories & Acceptance Criteria

### Story 1: Caching delivers consistent VLM advice (M5)

**As a** casual photographer in a slowly-changing scene
**I want** VLM coaching advice to be consistent when nothing has materially changed
**So that** I don't hear conflicting remarks about the same composition seconds apart.

**Acceptance Criteria:**
- [ ] A scene fingerprint (already computed by `SceneSignature`) is compared against a local cache before any VLM request is fired.
- [ ] Cache hit: the cached response is re-used without a network call if fingerprint similarity > threshold AND cache entry age < TTL.
- [ ] Cache miss (or TTL expired): VLM request fires as normal; response is stored in the cache.
- [ ] Cache is LRU-evicted when it exceeds a size limit (≤ 20 entries, configurable).
- [ ] On-device only, never persisted to disk across app launches — purely an in-session optimization.
- [ ] Cache is invalidated (bypassed) when stale-suppression would have discarded the response anyway.
- [ ] VLM offline / on-device-only mode: cache is irrelevant; no change to behavior.

### Story 2: Predictive coaching replaces premature corrective cues (M6)

**As a** photographer actively adjusting the shot
**I want** the app to recognize when I'm already fixing a problem and wait
**So that** I get encouraging feedback instead of repeated nagging for a condition I'm in the process of correcting.

**Acceptance Criteria:**
- [ ] The coaching pipeline tracks a rolling trend (last N frames) for each Tier-0 signal (tilt, exposure, blur).
- [ ] When a signal is outside threshold *but improving at sufficient rate* (configurable slope), a predictive hint is emitted instead of the corrective cue: e.g., "almost level" instead of "level it out," "light's getting better, hold a moment" instead of corrective exposure cue.
- [ ] Predictive hints have a wait window (default 2.5s). After the window:
  - If the signal has reached threshold → emit a positive cue ("nice, that's it") and go quiet.
  - If the signal has not reached threshold → revert to the standard corrective cue.
- [ ] Predictive cues are priority-ordered below stability/obstruction and above body/composition — they replace composition-level corrective cues, not emergency ones.
- [ ] Predictive mode does not fire for blur/shake (unpredictable, no reliable trend) — only tilt and exposure/light.
- [ ] A named constant `PredictiveCoach.defaultWaitWindowSeconds = 2.5` and `PredictiveCoach.defaultImprovementSlopeThreshold` define all tunable values; no bare literals.

### Story 3: Group-aware multi-person cues (M6)

**As a** photographer shooting a group of 2–5 people
**I want** the app to notice when someone is getting cut off and guide me at the group level
**So that** I don't end up with a photo missing half of one person.

**Acceptance Criteria:**
- [ ] When ≥2 person landmarks are detected with sufficient confidence, the pipeline enters group-aware mode.
- [ ] Group-level cues emitted (selection depends on detected geometry):
  - Edge proximity: "someone's getting cut off on the right — back up a bit"
  - Horizontal spread: "the group is spread wide — back up a touch"
  - Vertical headroom: "the group is a bit high in the frame — tilt down"
  - Lean cue: "have everyone lean in" (when subjects are too far apart relative to frame width)
- [ ] Group cues integrate into the existing cue engine at the same priority as body-positioning (Tier 0.5).
- [ ] When exactly 1 person is present (or dominant), single-subject coaching applies as in M2 — no regression.
- [ ] No per-person addressing ("person on the left…") — group-level direction only.
- [ ] No false group cues when confidence is below threshold or landmarks are ambiguous.

### Story 4: TestFlight beta phase (M7)

**As a** developer preparing for App Store launch
**I want** a defined beta period with real testers before public submission
**So that** launch-blocking bugs are caught before strangers see them.

**Acceptance Criteria:**
- [ ] TestFlight build distributed to 8–20 testers.
- [ ] Beta testers run the M4 validation session kit (including the group-photo task added in M6).
- [ ] All crash reports triaged within 24h of receipt; launch-blocking crashes fixed before submission.
- [ ] Exit criterion: 0 crash reports for 3 consecutive days.
- [ ] Testers confirm: (a) coaching feels real-time, (b) group cues fire when ≥2 people are in frame, (c) predictive hints feel natural rather than evasive.

### Story 5: App Store submission (M7)

**As a** developer submitting to the App Store
**I want** a clean, accurate submission that passes review on the first attempt
**So that** the app goes live without delays.

**Acceptance Criteria:**
- [ ] Minimum iOS version: **iOS 17.0** (Vision framework + Swift 6 concurrency APIs).
- [ ] Device support: **iPhone only** (no iPad-specific layout required); minimum **A15 Bionic** documented in App Store description (not enforced via capability, but stated to set expectations).
- [ ] Camera usage description in Info.plist is accurate and privacy-first.
- [ ] Privacy nutrition label accurately reflects: camera data used on-device only; frames sent to cloud VLM only with user consent (already gated by M4-3 ConsentGate); no account, no PII, no tracking.
- [ ] App Store listing includes: title, subtitle, description, up to 10 screenshots (required scenes: framing, body coaching, group coaching, consent screen, on-device-only mode).
- [ ] No use of private APIs; no third-party SDKs that require additional disclosure.
- [ ] On-device-only mode is clearly explained in the App Store description (not just in-app).

---

## Functional Requirements

### M5: Scene-Descriptor Caching

**Feature: VLM Response Cache**
- **What it is**: An in-session, on-device LRU cache that maps `SceneSignature` fingerprints to `AestheticSignal` responses. Prevents redundant VLM calls when the scene hasn't materially changed.
- **How it fits**: Sits between `VLMRequestGate` (which decides whether to call) and `VLMOrchestrator` (which fires the request). A cache hit short-circuits the gate — no network call, but the cached coaching advice is re-surfaced through the same `onAestheticSignal` path.
- **Cache key**: The CV/landmark scene fingerprint already computed in `SceneSignature`. Similarity threshold (not exact match) to handle minor frame-to-frame variation.
- **Cache entry**: `(fingerprint, AestheticSignal, timestamp)`. TTL: 30s (configurable). Max entries: 20 (LRU).
- **Invalidation**: TTL expiry + LRU eviction. Stale-suppression bypass (if the scene has genuinely changed, the existing stale-detection path discards the request before the cache is consulted).
- **On-device only**: Not persisted across app sessions. Pure memory.

**User flow**: camera settles → `SceneSignature` fingerprinted → cache consulted → if hit and not expired → re-surface cached advice → no VLM call → if miss → VLM request fires normally → response stored in cache.

**Edge cases**:
- Cache is bypassed entirely in on-device-only mode.
- Cache does not affect Tier-0 or Tier-0.5 paths — only VLM responses.
- If the cached advice is `.nothingToSay`, it counts as a cache hit (suppresses a VLM call) but emits nothing.

### M6: Predictive Coaching

**Feature: Signal Trend Detector**
- Tracks rolling slope of tilt angle and exposure histogram value over a configurable window (default: last 1.5s of frames).
- Emits `SignalTrend.improving(signal:)` when the slope exceeds `defaultImprovementSlopeThreshold` and the signal is still outside threshold.
- The cue engine consults `SignalTrend` before emitting a corrective cue: if `improving`, suppress corrective cue → emit predictive hint → start wait window timer.

**Feature: Predictive Cue Text**
New cue strings, same warm voice:
- Tilt: `"almost level"`, `"nearly there"`, `"just a touch more"`
- Exposure: `"light's getting better, hold a moment"`, `"nice, wait for the light"`
- Post-wait positive: `"that's it"`, `"perfect"`

**Feature: Group Presence Detector**

- Builds on `PresenceGate` (M2-1): counts confirmed person detections in one frame.
- If count ≥ 2: `GroupPresence.active(count: N)` state → routes landmark analysis to group-geometry path.
- Group geometry checks:
  - Bounding box union of all detected person boxes vs. frame edges → edge proximity cues.
  - Spread ratio (bounding box width / frame width) → lean-in cue.
  - Vertical placement of group centroid → headroom cue.
- Group cues feed `CueEngine` at `.bodyPositioning` priority (same level as M2 body cues).

### Out of Scope

- Per-person addressing ("person on the left…") — deferred to a future release.
- Predictive coaching for blur/shake (no reliable trend; not deferred, explicitly excluded).
- VLM server-side caching (Phase 3 if needed; Phase 2 cache is on-device only).
- Persistent cross-session caching (privacy risk without user consent flow; deferred).
- Tier-1 distilled on-device aesthetics model.
- Android / MediaPipe.
- Monetization, accounts, or subscription model.

---

## Technical Constraints

### Performance
- M5 cache lookup must add <1ms to the per-frame pipeline (hash lookup + TTL check — no computation).
- M6 trend detector operates on the existing `SignalFrame` values — no new CV computation. Rolling window stored in memory, lock-protected (`OSAllocatedUnfairLock`).
- Group presence detection reuses existing Vision body-detection output — no additional model inference.
- Combined pipeline (caching + trend + group) must not push Tier-0 latency above 150ms on A15 Bionic.

### Security & Privacy
- Cache stores only `AestheticSignal` (coaching text string + hint enum) — no image data, no fingerprint is persisted.
- Privacy nutrition label: `Camera` → `Used for core functionality, not collected`; `Other Data` → none; no tracking.
- ConsentGate (M4-3) already gates VLM frame transmission — no changes needed.
- Minimum iOS 17.0. No ATS exceptions beyond `NSAllowsLocalNetworking` (already scoped to localhost in M4 fix wave).

### Integration
- **M5**: `VLMResponseCache` integrates between `VLMRequestGate` and `VLMOrchestrator`. `SceneSignature` (already computed in `SignalFrameAccumulator`) is the cache key type.
- **M6**: `SignalTrendDetector` wraps `SignalFrameAccumulator` output and feeds into `CueEngine` via a new `onTrendUpdate` callback. `GroupPresenceDetector` extends `LandmarkOrchestrator`.
- **M7**: No new integration points. Validation session kit (M4-6) extended with group-photo tasks.

### Technology Stack
- Swift 6 strict concurrency throughout — all new types are `@unchecked Sendable` with `OSAllocatedUnfairLock` or `actor`.
- Swift Testing only (`import Testing`); ≥80% coverage on new logic.
- No new external dependencies for M5 or M6.
- Xcode / TestFlight for M7 distribution.

---

## MVP Scope & Phasing

### M5 (next): Scene-descriptor caching
Required before App Store launch to control VLM cost at scale.

**MVP Definition**: An in-session LRU cache that prevents redundant VLM calls on static scenes, measurably reducing call volume in the M7 beta telemetry.

### M6 (after M5): Predictive coaching + group-aware multi-person
Required before App Store launch to make coaching feel natural for group shots — the "take a photo of us" moment is the product's most differentiated use case.

**MVP Definition**: Predictive hints for tilt + exposure; group-level cues for ≥2 people; no per-person addressing.

### M7 (after M6): TestFlight beta + App Store submission
The launch milestone.

**MVP Definition**: Clean App Store submission that passes review, with 3 consecutive crash-free days on TestFlight and ≥70% real-time responsiveness confirmed in beta.

### Future Considerations
- Android + MediaPipe (Phase 3).
- Tier-1 distilled on-device aesthetics model.
- Persistent scene-descriptor caching (requires privacy consent flow).
- Per-person group choreography ("person on the left, turn slightly right").
- Adaptive coaching depth by skill level.
- Gesture detection (PicPal M2 nice-to-have, still unbuilt).

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Cache similarity threshold too loose → stale advice re-served after scene changes | Med | Med | Stale-suppression still runs as a second gate; tune threshold in M7 beta against telemetry |
| Predictive "wait" window trains users to delay shooting, missing the moment | Med | Med | Default window is short (2.5s); emit positive "that's it" immediately if threshold reached; do not block Tier-0 capture-ready signals |
| Group presence detector fires on crowds / background people | Med | Med | Presence confidence gate + minimum bounding-box area threshold; suppress group mode if confidence < floor |
| App Store review rejects on privacy grounds (VLM frame upload) | Low | High | ConsentGate already gates all uploads; privacy nutrition label accurately reflects opt-in-only VLM; on-device-only mode is a first-class feature prominently described |
| TestFlight reveals critical bug that delays App Store submission | Med | Med | 3-day crash-free exit criterion forces enough soak time; group-photo task in validation kit tests the new M6 path |

---

## Dependencies & Blockers

**Dependencies:**
- M4-7 (device validation run): must complete and confirm no blocking regressions before M5 work begins.
- `SceneSignature` fingerprint type (already built in M1-8): M5 cache key — no changes needed.
- `PresenceGate` + `LandmarkOrchestrator` (M2): M6 group detector extends these — no rework, just extension.

**Known Blockers:**
- M4-7 requires a real iPhone — no simulator substitute. Schedule the device validation run before starting M5 implementation.
- App Store submission requires an Apple Developer account in good standing and a signed Privacy Policy URL (can be a simple GitHub Pages URL for a free launch).

---

## Appendix

### Glossary
- **Scene fingerprint**: the CV/landmark hash of a frame computed in `SceneSignature`; used for stale-suppression (existing) and VLM response caching (M5).
- **TTL**: time-to-live — how long a cached VLM response is considered valid before a fresh call is preferred.
- **Signal trend**: the slope of a Tier-0 signal value (tilt angle, histogram exposure) over a rolling time window; positive slope when improving.
- **Predictive hint**: a coaching cue that acknowledges the user is actively correcting a problem and asks them to hold course, rather than repeating the corrective instruction.
- **Group-aware mode**: pipeline state when ≥2 person presences are detected with sufficient confidence; routes to group-geometry cue generation.
- **TestFlight**: Apple's beta distribution platform for pre-release iOS apps.

### References
- [picpal-prd.md](picpal-prd.md) — Phase 1 PRD (personas, tier architecture, acceptance criteria for M0–M4 features)
- [picpal-build-order.md](picpal-build-order.md) — milestone sequencing rationale
- [picpal-tickets-m4.md](picpal-tickets-m4.md) — M4 validation session kit (extended in M7 with group-photo tasks)

---

*This PRD was created through interactive requirements gathering with quality scoring to ensure comprehensive coverage of business, functional, UX, and technical dimensions.*
