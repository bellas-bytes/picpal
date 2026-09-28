# Architecture fixes: project manager handoff

Date: 2026-09-24. Owner: Staff Backend / AI engineer; independent reviewer evaluates after implementation. Specification: [architecture review](architecture-review.md). User authorized implementation and subsequent evaluation. Baseline is the current working tree, including extensive existing edits, not Git HEAD. Do not revert, overwrite, or commit unrelated work.

## Objective and constraints

Correct wasted cloud accounting, reduce avoidable reference startup work, expose real cloud latency, and bound the development proxy's resource use. Preserve device-first camera operation, consent and on-device-only checks, session/generation/geometry invalidation, the eight-second comparison freshness limit, single-flight behavior, and the 50-call client / 200-call server safety ceilings. Do not promise continuous reference readiness: with eight-second dispatch spacing and eight-second evidence validity, nonzero network latency necessarily creates gaps.

No repository AGENTS.md was found. Root completed the current-tree baseline: 742 Swift tests (792 parameterized executions), zero failures/skips, plus 11 passing Node tests using `node --test proxy/test/reference-analysis.test.js evals/reference-coaching/evaluate.test.mjs`. Swift result: `/tmp/picpal-architecture-baseline.xcresult`. Source snapshot: `/tmp/picpal-architecture-baseline-20260924.tar.gz`. These recorded results, rather than historical README counts or Git HEAD, define the comparison baseline.

## Priority 1: truthful cache and dispatch accounting

Files: `picpal/Sources/VLM/VLMRequestGate.swift`, `VLMOrchestrator.swift`, `VLMSessionStats.swift`; tests `VLMRequestGateTests.swift`, `VLMOrchestratorCacheTests.swift`, `VLMOrchestratorRetryTests.swift`.

- Separate non-consuming cadence/novelty eligibility from network budget consumption. Cache lookup must precede network budget consumption and remain available after network quota exhaustion.
- Maintain delivery cadence/novelty state for cache hits so a stationary frame does not repeatedly publish cached guidance.
- Spend one unit only immediately before a real client analyze attempt. Encoding failure, stale context, cancelled queued work, denied consent, and cache hits spend zero; each dispatched retry still spends one. Do not refund requests already sent.
- Compute the live scene signature once per frame and reuse it for invalidation, gating, cache, and dispatch.

Acceptance: deterministic tests cover cache hit with budget remaining and exhausted, repeated same-scene cache suppression, cache miss dispatch, encoding/pre-dispatch cancellation, and retry accounting. A seeded cache hit produces zero client calls and zero budget delta; an admitted network call produces exactly one of each.

## Priority 2: reference preparation and scheduling

Files: `picpal/Sources/VLM/ReferenceAnalysisCoordinator.swift`, `VLMOrchestrator.swift`, `FrameEncoder.swift`; relevant `ReferenceAnalysisCoordinatorTests.swift`, `ReferenceVLMTests.swift`, `FrameEncoderTests.swift`.

- Profile requests depend on the consented reference only. Do not require settled motion, encode a live frame, or reject a profile because the live scene changed. Trigger preparation promptly after consent/context establishment; retain context identity checks and cancel on revocation/replacement. Comparison requests retain live-frame freshness and scene/motion checks.
- Encode the consented reference once per valid context and reuse its in-memory JPEG. Clear bytes when removed, replaced, or consent is revoked. Geometry-only changes may reuse the same reference bytes; stale workers must not repopulate revoked cache state.
- Reuse a safely isolated Core Image context; preserve 512-pixel maximum dimension and existing JPEG quality.
- Centralize scheduling constants and make renewal policy explicit. Retain eight-second minimum spacing for new analyses and reference dispatches. Implementation clarification: preserve the existing bounded generic transport retry exception (one-second then two-second backoff, each attempt charged); reference dispatches have no automatic retries. Safe default remains sparse idle renewal. If implementing armed renewal, wire actual `CameraScreenModel.isArmed` through the composition root, renew at the earliest eligible time while armed/settled, and return to sparse behavior when disarmed. Document that this approaches 7.5 calls/minute and is incompatible with treating three calls/minute as a hard cap. The current three-call figure is only a target; do not silently claim it is met.
- A separate profile-versus-comparison cadence optimization may be considered only with explicit tests and a documented bounded cost policy. Do not simply shorten shared cadence or extend evidence lifetime.

Acceptance: a profile can complete while the phone is moving; comparison still cannot. Profile sends only reference data. Repeated comparisons reuse reference bytes. Replacement/revocation discards old work and bytes. Simulated time confirms no sub-eight-second network dispatches, ordinary idle refresh behavior, and armed/disarmed transitions if added. Tests must preserve stale comparison rejection.

## Priority 3: measurements that describe what actually completed

Files: `picpal/Sources/VLM/VLMSessionStats.swift`, `VLMOrchestrator.swift`, `picpal/Sources/Telemetry/PipelineTelemetryBridge.swift`, relevant telemetry/debug presentation and tests.

- Record request identity, operation, captured/dispatched/completed timestamps, encoding duration, cache hit/miss, attempted network calls, accepted results and stale discards. Measure asynchronous completion, not just callback return. Use a consistent clock domain with explicit camera timestamp conversion.
- Make metrics observable in existing debug/export facilities or a documented snapshot API; do not build an unused collector. Use bounded aggregation/ring storage and metadata only; no image bytes, prompts, or secrets in telemetry.
- Label existing bridge statistics accurately as scene-gated frame arrival and synchronous delegate-dispatch duration. Do not present them as capture FPS or complete inference latency.
- Focus this change on cloud and image preparation timing. Full sensor-to-caption/speech, local analyzer/drop metrics, capture-to-save duration, and thermal profiling remain explicit follow-ups unless the engineer can implement and verify them without broad rewrites.

Acceptance: deterministic clock tests demonstrate delayed asynchronous response increases completion latency; cache hits do not increase network attempts; stale result increments discard metrics; reset/bounds are tested; UI/export labels cannot imply unmeasured end-to-end performance.

## Priority 4: bounded development proxy

Files: `proxy/index.js`; extract testable app/resource-accounting modules as needed; add `proxy/test/` tests and proxy operator documentation.

- Bound active `/analyze` requests globally before multipart memory allocation. Reject excess work with actionable status and `Retry-After`; retain per-IP rate limiting and existing file-size limits. No unbounded waiting queue.
- Add explicit upstream timeout and disconnect cancellation, with abort propagation into the SDK. Release admission slots once on success, error, invalid upload, timeout, and disconnect. Disable invisible SDK retries or include them in a clearly enforced accounting model.
- Replace per-request synchronous counter writes with serialized async persistence and atomic replacement. Reserve/account admissions without races so concurrent requests cannot exceed the ceiling. Persistence errors must fail closed for new upstream work, not silently reset quota. Missing initial file may start at zero; corrupt/nonfinite/negative counters must not grant fresh quota.
- Preserve the persistent 200-call development ceiling; correct restart-reset wording and document explicit operator reset semantics. Expose remaining calls and concurrency status via health metadata without secrets.
- Retain reference request validation and response schema validation. Separate app construction from listening so tests use a mocked upstream and temporary counter storage.

Acceptance: deterministic concurrent tests exceed a small configured capacity and ceiling, confirming bounded upstream activity and no overspend; upload validation does not leak slots or consume quota; timeout/disconnect abort upstream and release resources; corrupt/write-failing counters fail safely; restart reloads count. No real paid upstream calls are required.

## Deferred scope and decisions

- Multi-instance shared quotas, caller authentication, billing identities, Redis/database infrastructure and public deployment require a hosting/authentication design. These development fixes do not establish production readiness.
- Preserve the capture/save transaction and failed-photo recovery. Burst throughput requires a product decision and durable bounded save design.
- Do not disable or consolidate diagnostic/local inference merely from static suspicion. First measure device inference duration, observation age, dropped work and thermal behavior, and prove diagnostic outputs are not product dependencies.
- No wholesale coordinator/UI architecture rewrite is needed for this work.

## Implementation and independent evaluation sequence

1. Save current-tree baseline diff/stat and runnable test results outside tracked source or in the final report. Record Swift environment limitations explicitly.
2. Implement each priority with failing regression tests first and run focused tests after each change. Keep changes additive/minimal around existing user work.
3. Run proxy/evaluation tests and the full available Swift suite; build the app. Document exact command, destination, exit status, and counts. Do not infer success from source inspection.
4. Hand the final diff, baseline results, post-change results and any policy deviations to an independent reviewer. Request correctness/security review of consent, budget races, cancellation and persistence in particular.
5. Independent evaluator compares measurable invariants: cache hit budget delta (1 → 0), redundant signature computations (2 → 1), profile live encodes (1 → 0), repeated reference encodes (per request → per context), upstream active requests (unbounded → configured cap), and synchronous request-path writes (present → absent). Only report each improvement if implementation/tests substantiate it.
6. Report measured test/mock improvements separately from device/runtime hypotheses. Battery, thermal load, camera FPS, real Anthropic latency, usable-reference coverage, speech latency and photo throughput require physical-device or real-service profiling and cannot be claimed from static analysis or simulator unit tests.

## Independent evaluator acceptance checklist

- [ ] Compare implementation against the archived current-tree baseline; distinguish pre-existing user changes.
- [ ] Verify cache hits spend zero network quota, including with exhausted quota; actual attempts/retries spend exactly one each.
- [ ] Verify profile preparation needs only consented reference data; comparisons retain motion, scene, context and freshness checks.
- [ ] Verify reference bytes are reused and revoked/replaced data cannot be retained or repopulated by stale work.
- [ ] Verify scheduling preserves minimum cadence and explicitly reports any armed-renewal cost tradeoff.
- [ ] Verify observable asynchronous metrics and accurate labels, with bounded storage and no private image/prompt data.
- [ ] Verify proxy admission precedes upload allocation, concurrency stays bounded, cancellation/deadlines reach upstream, and every exit releases admission once.
- [ ] Verify serialized atomic quota persistence, no ceiling overspend, safe malformed/write-failure behavior, and persistence across restart.
- [ ] Compare post-change Swift/Node results with 742 Swift tests / 792 executions and 11 Node baseline passes; explain any missing, failing or skipped cases.
- [ ] Report each claimed improvement with code/test evidence; explicitly separate device/service measurements still outstanding.
