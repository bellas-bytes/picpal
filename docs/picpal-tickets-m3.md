# PicPal — M3 Tickets (Tier 2 · VLM Aesthetic Coaching)

**Companion to**: [picpal-build-order.md](picpal-build-order.md) · [m3-vlm-aesthetic-coaching-prd.md](m3-vlm-aesthetic-coaching-prd.md)
**Date**: 2026-08-11
**Platform**: iOS (Swift 6, URLSession) + Node proxy
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

> **Milestone target**: Aesthetic cues appear only on stable, novel frames, never delay Tier 0/0.5, and are silently dropped when the moment has passed. **The app remains fully functional and feels identical with the VLM offline.**

## Locked decisions (2026-08-11)

1. **Model: Claude Sonnet 5** behind a swappable `VLMClient` protocol.
2. **Proxy: local dev proxy first** (Node on the dev Mac, over LAN). Deployment to a real host is M3-7, not a build-out blocker.
3. **Gesture detection stays Phase 2** — out of scope for M3.
4. **Cost controls: cadence cap + per-session budget**, both named constants, both enforced client-side *and* server-side.

## Conventions (carried from M0/M1/M2)

- Every signal producer writes an immutable snapshot into `SignalFrame`; producers are pure — they compute, they don't speak. M3 adds a single `AestheticSignal` field.
- Swift 6 strict concurrency (`@unchecked Sendable` + `OSAllocatedUnfairLock`; `nonisolated` delegate methods).
- **Swift Testing** only (`import Testing`), ≥80% coverage on new logic.
- 300-line file limit; no magic numbers (named `static` constants).
- **Tier-0 forwarding invariant**: `downstream?.cameraCapture(...)` is the first statement in every `CameraFrameDelegate` method. Non-negotiable.
- M0-4 perf/thermal telemetry stays on — M3 adds sustained radio use, a new battery vector.

---

## M3-0 — VLM proxy service + swappable client abstraction  ⚠ SPIKE
**Size**: L · **Deps**: M2 complete · **Risk-critical**

Stand up the proxy, prove round-trip latency against the <3 s budget, and fix the client contract before any feature work commits to it. Produces a go/no-go, not shippable cues.

**Acceptance criteria**
- [ ] Node proxy in `proxy/` (outside the Xcode target): accepts a JPEG + prompt, calls Claude Sonnet 5, returns the text response.
- [ ] **API key never on-device**: key read from proxy environment only; `proxy/.env` git-ignored; a committed `.env.example` documents required vars. Verify no key appears in the iOS binary, source, or `project.yml`.
- [ ] Server-side rate limit and hard call ceiling, enforced independently of any client-side gate.
- [ ] Proxy logs request metadata only — **never** image bytes.
- [ ] `VLMClient` protocol: async throwing call, cancellation support, vendor-agnostic request/response types. `AnthropicVLMClient` is the one conformance.
- [ ] **Round-trip latency measured** over ≥20 real calls at the target JPEG resolution; p50/p95 recorded and compared to the 3 s budget.
- [ ] Written go/no-go: if p95 > 3 s, invoke the fallback ladder (lower resolution → shorter max-tokens → Haiku 4.5) and record the choice before M3-4 starts.

---

## M3-1 — Frame encoder (downscale → JPEG)
**Size**: S · **Deps**: M3-0 (wire format only)

Pure `CVPixelBuffer` → minimized JPEG conversion. The privacy boundary in code form: this is the single place frame data becomes transmittable.

**Acceptance criteria**
- [ ] `FrameEncoder.encode(pixelBuffer:) -> Data?` — downscales to a named max-dimension constant, JPEG-compresses at a named quality constant.
- [ ] Output size is bounded and asserted in tests; a 4K input never produces an oversized payload.
- [ ] Pure and stateless — no I/O, no disk writes, no caching. **Nothing is ever persisted.**
- [ ] Returns `nil` (not a crash, not a partial buffer) on any unlockable or malformed pixel buffer.
- [ ] Unit-tested with synthetic buffers: normal, tiny, non-standard aspect ratio, unlockable.

---

## M3-2 — VLM request gate: settle + novelty + cadence + budget
**Size**: M · **Deps**: M1-8 (`SceneGate`, `SceneSignature`)

The four-gate authorization layer. Mirrors `LandmarkCadenceController`'s shape — this is the pattern the codebase already trusts.

**Acceptance criteria**
- [ ] `VLMRequestGate.shouldRequest(pixelBuffer:isSettled:) -> Bool` requires **all four**: settled AND scene materially changed since the **last request** (not the last frame) AND ≥ cadence-cap interval elapsed AND session budget remaining.
- [ ] Cadence cap and session budget are named constants; changing either is a one-line edit.
- [ ] `VLMSessionBudget` is a lock-protected counter; exhaustion is sticky for the session and reported distinctly from a network failure.
- [ ] Injectable clock (mirroring `LandmarkCadenceController` and `CueEngine`) so cadence is testable without real delays.
- [ ] Unit-tested per gate in isolation and in combination: each gate alone blocks; all four passing permits; budget exhaustion is permanent for the session.

---

## M3-3 — Stale-suppression + response matching
**Size**: M · **Deps**: M3-2

The correctness heart of M3. A cue describing a frame the user has left is a hard defect — the KPI is 100%, not "mostly."

**Acceptance criteria**
- [ ] `StaleSuppressor` builds a request tag from the frame's `SceneSignature` **and** the concurrent `BodySignal.hint`.
- [ ] On response, re-compares: discard if `SceneSignature.isMateriallyDifferent` is true **or** the body hint changed category.
- [ ] **Discard-on-ambiguity**: if the current signature cannot be computed, discard. Never emit on uncertainty.
- [ ] Discarding is silent — no cue, no user-visible error, no UI flicker. Debug overlay may count discards.
- [ ] Unit-tested: unchanged scene → passes; luminance shift → discarded; body hint change → discarded; nil signature → discarded.

---

## M3-4 — AestheticSignal + prompt design + response parsing
**Size**: M · **Deps**: M3-0

Turn model prose into a typed signal, or into silence. **Silence is a valid and preferred output** — this ticket's job is as much rejection as parsing.

**Acceptance criteria**
- [ ] `AestheticSignal` value type (mirrors `BodySignal`): remark text + confidence + a `.nothingToSay` sentinel.
- [ ] Prompt instructs the model to return **either** one short action-first remark **or** an explicit "nothing to say" token — documented verbatim in the source.
- [ ] `AestheticResponseParser` is pure and strict: long, hedging, multi-suggestion, or malformed responses parse to `.nothingToSay`, not to a cue.
- [ ] A remark exceeding a named max-length constant is rejected rather than truncated — a half-sentence coach is worse than a quiet one.
- [ ] Unit-tested against recorded fixture responses: good remark, "nothing to say" token, over-long, multi-suggestion, empty, malformed JSON, model refusal.

---

## M3-5 — VLMOrchestrator + cue-engine wiring at `.aesthetic`
**Size**: M · **Deps**: M3-1, M3-2, M3-3, M3-4

Wire the tier into the live pipeline. `CuePriority.aesthetic` (rawValue 4) and `CueSourceTier.tier2` have been reserved since M1-5 — no new priority cases.

**Acceptance criteria**
- [ ] `VLMOrchestrator: CameraFrameDelegate` — forwards downstream **first**, then gates, then dispatches off the camera queue. Mirrors `LandmarkOrchestrator`.
- [ ] **At most one request in flight**; new candidates during flight are dropped, never queued (`OSAllocatedUnfairLock<Bool>` busy flag, as in `LandmarkOrchestrator`).
- [ ] Hard request timeout (named constant) with cancellation; a timed-out request never produces a cue.
- [ ] `SignalFrame.aesthetic` field added; `SignalFrameAccumulator.update(aesthetic:)` added, forwarding preserved in all existing update methods.
- [ ] `CueEvaluator.evaluate()` gains a block **after** body (4.5), before `return nil`, emitting `Cue(priority: .aesthetic, sourceTier: .tier2)`. Existing debounce/cooldown/hysteresis unchanged.
- [ ] `.nothingToSay` → `nil`. No filler cue, ever.
- [ ] Debug overlay shows the active aesthetic remark and an in-flight indicator.

---

## M3-6 — Offline degradation + on-device-only mode + privacy copy
**Size**: M · **Deps**: M3-5

The trust surface. This is the first milestone where data leaves the device, so this ticket carries the privacy story for the whole product.

**Acceptance criteria**
- [ ] Proxy unreachable / network down / budget exhausted → Tier 0 and Tier 0.5 continue **completely untouched**.
- [ ] Degradation is **quiet**: no error banner, no spoken apology, no retry storm. Debug-overlay indicator only.
- [ ] Bounded retry with backoff; repeated failure disables Tier 2 for the remainder of the session rather than retrying indefinitely.
- [ ] **On-device-only toggle** short-circuits **before** `FrameEncoder` runs — no encoding, no request construction. Verified by test, not by inspection.
- [ ] Toggle state persists across launches.
- [ ] Privacy copy states: Tier 0/0.5 (all body, face-mesh, hand data) never leaves the device; Tier 2 sends a downscaled JPEG of an occasional stable frame at a stated resolution cap; no location, identity, or account; nothing persisted by app or proxy.
- [ ] Disclosure is reachable from the same surface as the toggle.

---

## M3-7 — Integration, deployment & validation
**Size**: M · **Deps**: M3-6

No new signals — wire everything, prove the invariants, deploy the proxy for real sessions.

**Acceptance criteria**
- [ ] **Non-regression (milestone-failure criterion)**: with Tier 2 active, Tier-0 FPS ≥ 25 and Tier-0/0.5 cue latency < 150 ms, matching the M2 on-device baseline within measurement noise.
- [ ] **Stale-suppression walkthrough**: deliberately pan away mid-request; verify the response is discarded and no cue fires. Repeat ≥10 times — expect 10/10.
- [ ] **Offline walkthrough**: airplane mode mid-session; verify Tier 0/0.5 continue and degradation is silent.
- [ ] **On-device-only walkthrough**: toggle off; verify via proxy logs that zero requests arrive over a sustained run.
- [ ] **Cost check**: a 5-minute session stays within the session budget, verified by proxy-side call count.
- [ ] **Battery/thermal**: 5-minute session with Tier 2 on vs. off; battery delta recorded via the M0-4 harness; thermal stays nominal.
- [ ] Non-annoyance: cue-count distribution per stable episode stays in the ~1–3 band against the M2 baseline.
- [ ] Integration tests (Swift Testing) for the `AestheticSignal → cue` path, mirroring `BodyCueIntegrationTests`.
- [ ] **Proxy deployed** to a real host with the key in host env; client points at the deployed URL; demo-script section added for the M3 scenarios.

**M3 exit**: aesthetic cues land on stable novel frames, never delay the loop, vanish when the moment does — and the app is indistinguishable from M2 with the VLM off. Ready for M4 tuning & validation.

---

## Out of scope (M3)
- **Gesture detection** — Phase 2 (locked decision 3).
- **Scene-descriptor caching** to cut VLM spend — Phase 2.
- Tier-1 distilled on-device aesthetics model.
- Predictive/temporal coaching; multi-person group choreography.
- Prompt fine-tuning or a custom model.
- Post-capture features (editing, filters, sharing, accounts, storage).

## Carried-forward blockers (not M3-blocking, but M3-7-blocking)
- **M2 on-device p95 is still `PENDING_DEVICE_RUN`.** M3-7's acceptance bar is "no regression from the M2 baseline" — that baseline must be measured on a real device first.
- `project.yml` references `PicPal/` while the directory is `picpal/` — breaks a case-sensitive CI. M3 adds a second deployable, which may finally prompt CI setup.

## Dependency graph
```
M3-0 (proxy + client protocol) ⚠SPIKE ──┬─> M3-1 (frame encoder) ──┐
                                        └─> M3-4 (signal + prompt) ─┤
M3-2 (request gate: 4 gates) ──┬───────────────────────────────────┼─> M3-5 ──> M3-6 ──> M3-7
                               └─> M3-3 (stale-suppression) ───────┘
```
M3-0 is the risk-critical spike and gates the client contract. M3-2 is independent of it and can run in parallel. M3-5 is the integration point; M3-6 and M3-7 are strictly sequential after it.
