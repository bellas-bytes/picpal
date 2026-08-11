# Product Requirements Document: Aesthetic Coaching (M3 — Tier 2 VLM)

**Version**: 1.0
**Date**: 2026-08-11
**Author**: Sarah (Product Owner)
**Companion to**: [picpal-prd.md](picpal-prd.md) v1.1 · [picpal-build-order.md](picpal-build-order.md) · [m2-body-aware-coaching-prd.md](m2-body-aware-coaching-prd.md)
**Quality Score**: 91/100

> **Supersedes** the "M3 High-Level Evaluation (68/100)" section of the M2 PRD. All four open decisions listed there are now closed — see **Locked Decisions**.

---

## Executive Summary

M0–M2 built a coaching loop that is fast and body-aware but *mechanical*. It knows the horizon is crooked, the subject's arm is cropped, and a thumb is over the lens. It does not know that the shot is boring, that the moment is candid and worth holding, or that there is too much empty sky.

M3 adds **Tier 2** — a cloud vision-language model that supplies the one thing keypoint geometry cannot: taste. A frontier VLM looks at an occasional stable, novel frame and returns a short qualitative remark ("this feels candid — hold it," "too much empty sky").

The defining constraint is what M3 is **not** allowed to do. It must never enter the real-time critical path. Tier 0 and Tier 0.5 already own the loop and already work. M3 is upside layered on top: it fires only on settle events, at a hard cadence cap, and its advice is discarded silently the moment the scene moves on. **The app must remain fully functional, and feel identical, with the VLM offline.**

This is also the milestone where PicPal first sends data off-device. Everything before M3 was on-device by construction. M3 therefore carries the privacy surface for the whole product: an explicit "what leaves the device" statement, minimized-resolution frames, and a user-facing on-device-only mode that turns Tier 2 off entirely.

---

## Problem Statement

**Current Situation**: After M2, PicPal reliably fixes mechanical faults — tilt, blur, exposure, framing, crops, gaze, obstruction. A user can follow every cue, get a technically clean photo, and still have a photo nobody wants to look at. The app has no concept of a photograph being *good*, only of it being *correct*.

**Proposed Solution**: An asynchronous aesthetic tier. On a stable, materially-new frame, a minimized JPEG goes to a thin proxy service, which calls a frontier VLM with a tightly-scoped prompt. The response becomes at most one short cue at the lowest priority in the existing cue engine, and only if the scene it described still exists.

**Business Impact**: Aesthetic remarks are the shareable moments — the cues users quote to a friend. They are also the clearest differentiator from a static grid overlay. But they are worth nothing if the loop stops feeling real-time, which is why every requirement in this document is written defensively around that risk.

---

## Locked Decisions (2026-08-11)

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Model: Claude Sonnet 5** | Best latency/cost balance at the ~1 call/2–4 s cadence, and strong at the qualitative candid/composition judgment M3 needs. Sits behind a swappable `VLMClient` protocol — moving to Opus 5 is a conformance change, not a refactor. |
| 2 | **Proxy: local dev proxy first** | A small Node service on the developer's Mac, reached over LAN. Zero infra cost or accounts during build-out; the on-device client abstraction is byte-identical to what a deployed host will require. Deployment to a real edge host is a tracked pre-session ticket (M3-7), not an M3-0 blocker. |
| 3 | **Gesture detection stays in Phase 2** | It is on-device MediaPipe work with no dependency on the VLM tier. M3 already carries network, async, cost, and privacy risk; adding an unrelated signal would widen the milestone for no architectural gain. |
| 4 | **Cost controls: per-session call budget + cadence cap** | Cadence cap (≥2 s between calls) bounds burst rate; a per-session hard budget bounds total spend. Both are named constants. Exhausting the budget degrades exactly like being offline. |

---

## Success Metrics

**Primary KPI (inherited, must not regress):**
- **Perceived real-time responsiveness stays ≥70%.** M3 is a success only if the Tier 0/0.5 loop feels *no different* with the VLM on. Any measurable regression here is a milestone failure regardless of cue quality.

**M3-specific KPIs:**
- **Zero critical-path impact**: Tier-0 FPS ≥ 25 and Tier-0/0.5 cue latency < 150 ms with Tier 2 active — identical to the M2 baseline within measurement noise.
- **Stale-suppression correctness**: 100% of responses describing a materially-changed scene are discarded. A cue referencing a frame the user has moved past is a hard defect, not a tuning issue.
- **Aesthetic cue usefulness**: ≥50% of VLM cues rated "worth saying" in moderated review. Lower bar than Tier 0/0.5 by design — taste is subjective, and silence is an acceptable output.
- **Non-annoyance holds**: adding Tier 2 must not push median cues per stable episode above the ~1–3 band.
- **Cost per session**: ≤ the per-session budget constant, verified by proxy-side call counting over a 5-minute session.

**Validation**: The M3-7 fault-injection walkthrough plus a VLM-on/VLM-off A/B in the moderated sessions (M4).

---

## User Personas

Both M3 personas are the existing v1 co-primaries, in a specific mode.

### Primary: "Casual Cam, already satisfied"
- **Role**: Has followed every mechanical cue. The frame is level, sharp, well-exposed, well-composed. Tier 0/0.5 have gone quiet.
- **Goal**: Wants to know whether this is actually a *good* photo, or merely a correct one.
- **Pain Point**: Silence is ambiguous — it reads as "nothing more to say," not "this is good." Confidence to press the shutter is the missing output.
- **Why M3 serves them**: The aesthetic tier fires precisely in the gap the mechanical tiers leave behind.

### Secondary: "Sharing Sam, mid-moment"
- **Role**: Photographing a person who is laughing, moving, being candid.
- **Goal**: To recognize the moment worth holding — the thing a real photographer would say "yes, that, stay there" about.
- **Pain Point**: Candidness is exactly what keypoint geometry cannot see. A perfectly-posed frame and a joyful one are geometrically identical.
- **Why M3 serves them**: This is the highest-value VLM output in the product, and unreachable by any cheaper tier.

---

## User Stories & Acceptance Criteria

### Story 1: Aesthetic remark on a settled, novel frame
**As a** casual photographer **I want** an occasional smarter observation **so that** composition improves beyond mechanics.
- [ ] A VLM call fires only when **all** gates pass: motion-settled AND scene materially changed since the last call AND ≥ cadence-cap interval elapsed AND session budget not exhausted.
- [ ] The response yields at most one cue at `.aesthetic` priority, `sourceTier: .tier2`.
- [ ] A response with nothing worth saying produces **silence**, not a filler cue. "Silence is a valid output" is a hard requirement, not a fallback.
- [ ] End-to-end (shutter-stable → spoken aesthetic cue) completes within **3 s**, or is dropped.

### Story 2: The VLM never blocks the loop
**As a** casual photographer **I want** the app to stay instantly responsive **so that** coaching still arrives in time to act.
- [ ] All VLM work — encoding, network, parsing — runs off the camera delivery queue. `downstream?.cameraCapture(...)` forwarding remains the first statement in the delegate, as with `LandmarkOrchestrator`.
- [ ] Drop-if-busy backpressure: a new candidate frame while a request is in flight is dropped, never queued. At most one request is outstanding at any time.
- [ ] Tier-0 FPS and Tier-0/0.5 cue latency are unchanged from the M2 baseline with Tier 2 active (verified via the M0-4 harness).
- [ ] A slow or hanging request is cancelled at a named timeout and never produces a cue.

### Story 3: Stale-suppression
**As a** casual photographer **I want** advice about the shot I'm looking at now **so that** the coach never feels confused.
- [ ] Every request is tagged with the frame's `SceneSignature` **and** the concurrent `BodySignal.hint`.
- [ ] On response, the tag is re-compared against the current scene. If `isMateriallyDifferent` is true, or the body hint has changed category, the response is **discarded silently** — no cue, no log noise, no UI flicker.
- [ ] Discarding is the default on any ambiguity: if the current signature cannot be computed, the response is dropped.

### Story 4: Offline and degraded operation
**As a** casual photographer **I want** the app to keep working without a network **so that** it is never dead weight.
- [ ] With the proxy unreachable, the network down, or the session budget exhausted, Tier 0 and Tier 0.5 continue completely untouched.
- [ ] Degradation is **quiet and non-alarming** — no error banner, no spoken apology, no retry storm. At most a debug-overlay indicator.
- [ ] Failed requests use bounded retry with backoff; repeated failure disables Tier 2 for the remainder of the session rather than retrying indefinitely.

### Story 5: On-device-only mode (privacy control)
**As a** privacy-conscious user **I want** to turn off everything that leaves my phone **so that** I control my own camera data.
- [ ] A user-facing toggle disables Tier 2 entirely. When off, **no frame data is encoded, and no network request is constructed** — the off path short-circuits before encoding, not at the network layer.
- [ ] The toggle's state persists across app launches.
- [ ] With the toggle off, the app behaves exactly as it did at end-of-M2.

### Story 6: Explicit privacy disclosure
**As a** user **I want** to know what leaves my device **so that** I can make an informed choice.
- [ ] Copy states plainly: Tier 0 and Tier 0.5 (including all body, face-mesh, and hand landmark data) are **fully on-device and never transmitted**.
- [ ] Copy states what Tier 2 sends: a **downscaled JPEG** of an occasional stable frame, no location, no identity, no account, and states the resolution cap.
- [ ] Copy states that frames are not persisted by the app and are not retained by the proxy beyond the request.
- [ ] The disclosure is reachable from the same surface as the on-device-only toggle.

---

## Functional Requirements

### Tier ownership (M3 additions only)

| Concern | Owner | Notes |
|---------|-------|-------|
| Call gating (settle + novelty + cadence + budget) | `VLMRequestGate` | Mirrors `LandmarkCadenceController`'s multi-gate shape |
| Frame → wire format | `FrameEncoder` | Downscale + JPEG; pure and unit-testable |
| Request/response transport | `VLMClient` protocol | `AnthropicVLMClient` is the M3 conformance |
| Staleness | `StaleSuppressor` | Owns tag construction and the discard decision |
| Response → signal | `AestheticResponseParser` | Pure; tolerates malformed model output |
| Pipeline integration | `VLMOrchestrator` | `CameraFrameDelegate`, mirrors `LandmarkOrchestrator` |
| Spend | `VLMSessionBudget` | Lock-protected counter, per-session |

### Core behaviors
- **New signal type** `AestheticSignal` written into a new `SignalFrame.aesthetic` field, following the `BodySignal` precedent exactly (immutable snapshot, producer is pure, no speaking, no UI).
- **Cue-engine integration** at the already-reserved `CuePriority.aesthetic` (rawValue 4) — the lowest priority. Existing debounce, cooldown, and repeat-suppression are unchanged. An aesthetic cue can never bypass a cooldown, since nothing ranks below it.
- **Prompt is tightly scoped**: the model is instructed to return either one short action-first remark or an explicit "nothing to say" token. Long, hedging, or multi-suggestion responses are treated as parse failures and dropped.
- **Proxy responsibilities**: holds the API key, enforces a server-side rate limit and call ceiling independent of the client, supports request cancellation, and logs nothing containing image data.

### Out of Scope (M3)
- Gesture detection (Phase 2 — locked decision 3).
- Scene-descriptor caching to reduce VLM spend (Phase 2 per the main PRD).
- Tier-1 distilled on-device aesthetics model.
- Predictive/temporal coaching ("light's improving, wait 2 s").
- Multi-person group choreography.
- Prompt fine-tuning or a custom model.
- Any post-capture feature (editing, filters, sharing, accounts, storage).
- Production deployment of the proxy beyond the M3-7 pre-session ticket.

---

## Technical Constraints

### Performance & cadence
- VLM cue budget: **< 3 s** end-to-end, else dropped. Named timeout constant.
- Cadence cap: **≥ 2 s** between calls (target band 2–4 s). Named constant; one-line adjustable.
- At most **one** request in flight. New candidates during flight are dropped, never queued.
- Frame encoding runs on a dedicated queue, never the camera queue.
- Tier-0 FPS ≥ 25 and Tier-0/0.5 latency < 150 ms must hold with Tier 2 active — the M2 baseline is the acceptance bar.

### Security & Privacy
- API key lives **only** in the proxy. The key must never appear in the iOS binary, in source, in `project.yml`, or in any committed config. Proxy config is git-ignored and read from environment.
- Frames are transmitted at minimized resolution (named cap constant), JPEG-compressed.
- No image data, location, identity, or account data in URLs or query strings — image payload is in the request body only.
- Face-mesh, hand, and pose landmark data **never leave the device**, in any milestone. M3 does not change this.
- No frame is persisted to disk by the app at any point in the M3 path.

### Integration
- `VLMClient` is a protocol with an async throwing call and cancellation support; `AnthropicVLMClient` is one conformance. Swapping vendors must not touch the gate, encoder, suppressor, parser, or orchestrator.
- Proxy is a separate deployable in-repo (e.g. `proxy/`), not part of the Xcode target.

### Platform / code standards (unchanged project constraints)
- Swift 6 strict concurrency: `@unchecked Sendable` + `OSAllocatedUnfairLock`; `nonisolated` delegate methods.
- **Swift Testing** only (`import Testing`, `@Test`, `#expect`), ≥80% coverage on new logic.
- 300-line file limit; no magic numbers (named `static` constants).
- M0-4 perf/thermal telemetry stays on — this milestone adds sustained radio use, a new battery vector the harness must now watch.

---

## Risk Assessment

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| VLM latency degrades the real-time feel | Med | **High** | Never in critical path; one in-flight request; hard timeout; drop-if-busy; FPS/latency regression is a milestone-failure criterion |
| Stale cue describes a frame the user left | Med | **High** | Dual-tag (SceneSignature + BodySignal); discard-on-ambiguity default; 100% correctness KPI |
| Aesthetic cues are generic filler ("nice shot") | **High** | Med | Explicit "nothing to say" token; parse-strict prompt; silence preferred over filler; usefulness KPI at 50% |
| Radio use tanks battery over a long session | Med | Med | Cadence cap + session budget bound total calls; M0-4 harness extended to watch battery delta with Tier 2 on vs. off |
| API key leaks into the client or a commit | Low | **High** | Key exists only in proxy env; git-ignored config; pre-commit secret scan in M3-0 acceptance |
| Cost scales badly during development | Med | Med | Per-session budget constant + independent server-side ceiling; both enforced, neither trusted alone |
| Chattiness regresses the non-annoyance band | Med | Med | Lowest priority, cannot bypass cooldown; M3-7 measures cue-count distribution against the M2 baseline |
| Local dev proxy diverges from a deployed host | Med | Low | Identical client contract; deployment is a tracked M3-7 ticket before any user session |

---

## Dependencies & Blockers

**Dependencies:**
- M2 complete and merge-ready (✅ — `develop` @ `e9ea7d9`, 340 tests).
- `SceneSignature` + `SceneGate` settle/novelty infrastructure (✅ — M1-8).
- `CuePriority.aesthetic` and `CueSourceTier.tier2` slots (✅ — reserved since M1-5).
- Anthropic API access for Claude Sonnet 5.
- Node runtime on the development machine for the local proxy.

**Known Blockers:** None. All four M2-era open decisions are closed above.

**Carried forward from M2 (unresolved, not M3-blocking):**
- On-device p95 latency validation for the M2 landmark path is still `PENDING_DEVICE_RUN`. M3's FPS/latency acceptance bar is "no regression from the M2 baseline," so that baseline must be measured on-device before M3-7 can pass.
- `project.yml` case-sensitivity issue (`PicPal/` vs `picpal/`) — will break a case-sensitive CI, and M3 adds a second deployable that may prompt CI setup.

---

## Appendix

### Glossary
- **Tier 2**: The async cloud VLM tier — aesthetic judgment only, never in the critical path.
- **Settle event**: Motion below threshold AND material scene change — the trigger to escalate to the VLM.
- **Stale-suppression**: Discarding VLM advice whose frame the user has already moved past.
- **Request tag**: The `SceneSignature` + `BodySignal.hint` pair captured at request time and re-compared at response time.
- **Session budget**: A hard per-session ceiling on VLM calls; exhaustion degrades identically to offline.
- **On-device-only mode**: User-facing toggle disabling Tier 2 before any encoding occurs.

### References
- [picpal-prd.md](picpal-prd.md) — v1.1 product PRD, Story 3 and the tier stack.
- [picpal-build-order.md](picpal-build-order.md) — M3 milestone definition and sequencing principles.
- [m2-body-aware-coaching-prd.md](m2-body-aware-coaching-prd.md) — M2 PRD; its M3 evaluation section is superseded here.
- [picpal-tickets-m3.md](picpal-tickets-m3.md) — the executable ticket breakdown.
