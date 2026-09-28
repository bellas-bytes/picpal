# Independent architecture improvement evaluation

Reviewed September 24, 2026 after the Staff Backend / AI implementation. This evaluation compares the saved current-tree source archive `/tmp/picpal-architecture-baseline-20260924.tar.gz` (extracted to `/tmp/picpal-evaluator-baseline`) with the implementation. Git HEAD is not the baseline: the working tree already contained substantial unrelated user work.

The implementation materially improves cloud accounting, reference preparation, observable completion timing, and bounded single-process proxy operation. These are source-level and deterministic-test results, not measurements of physical-device speed or real Anthropic response time.

## Before and after

| Area | Baseline | Implemented result and evidence |
|---|---|---|
| Cache quota | Gate consumed one allowance before cache lookup | Seeded cache hits use zero network attempts and zero allowance, even with zero remaining quota. `cacheDeliveryNeverConsumesNetworkBudget` covers capacities 0 and 2 and suppresses repeated stationary delivery. |
| Actual attempts | Initial allowance could be spent before encoding/transport | Consumption occurs immediately before `client.analyze`; failed encoding and context change before dispatch spend zero. Retry tests assert three attempts spend three allowances. |
| Scene signature | Generic frame computed twice | `cameraCapture` computes once and reuses the signature for invalidation, eligibility, lookup, and dispatch. Verified against archive; no timing claim. |
| Profile preparation | Required a settled live frame and encoded it before omitting it from profile upload | `setReferenceContext` starts profile preparation without a camera frame. `profileStartsWithoutCameraFrameOrSettledMotion` verifies dispatch/completion while moving and an empty live-image payload. |
| Reference JPEG | Encoded on each request | Coordinator retains consented bytes for reuse, preserves them across geometry change, clears them on replacement/revocation, and rejects old-epoch writes. Coordinator tests cover geometry, replacement, revocation, and stale-worker rejection. `referenceMode_bypassesCache` independently counts one reference encode across a profile plus two comparisons; those comparisons produce exactly two live encodes. |
| Rendering setup | Created a `CIContext` per live encode | One shared context; per-call images/destinations remain separate. Existing 512-pixel/quality behavior remains. No CPU or thermal reduction measured. |
| Renewal | Sparse 20-second refresh | Armed state is wired from `CameraScreenModel` and enables renewal at 8 seconds; disarming returns to 20 seconds. Simulated coordinator test verifies 107.99/108 seconds and disarmed 116/128-second boundaries. |
| Completion metrics | Cache counters and synchronous callback timing | Metadata snapshot records request identity, operation, capture/preparation time, dispatch, awaited completion, encoding duration, attempts and outcome. Delayed profile test records 4 seconds only after async completion; bounds/reset test retains 128 of 140 records. |
| Proxy admission | Per-IP rate limit without global in-flight bound | Default four active requests, admitted before multipart allocation, no waiting queue, excess 503 plus `Retry-After`. Test holds an upload open and verifies rejection and timeout without quota. |
| Cancellation | No explicit route-level disconnect/deadline propagation | Total 30-second deadline and disconnect abort the SDK request. Tests verify abort and exactly-once release. SDK retries explicitly disabled. |
| Persistence | Synchronous JSON write; errors/corruption could reset or lose quota | Serialized async temporary write plus atomic rename before dispatch, independently bounded pending writes, fail-closed invalid/write-failed ledger, no overspend and restart persistence tests. |

Reference scheduling retains eight-second spacing for newly scheduled analyses, and comparison freshness remains eight seconds from capture. The established generic retry exception remains: at most two retries with 1-second then 2-second delays, each consuming quota. The coordinating agent accepted this scope clarification during evaluation. Thus the handoff's original absolute “no sub-eight-second network dispatches” wording is **not** met literally; the reference path has no retry exception. Armed renewal approaches 7.5 calls/minute, rather than a hard three-call/minute cap. Both client 50-call and proxy 200-call ceilings remain.

## Review and acceptance

Consent, session/generation/geometry epochs, pre-dispatch checks, and result invalidation remain in the reviewed reference path. A changed live scene does not invalidate a profile; comparison dispatch still requires settled motion, and comparison responses retain context/age/live-signature checks. The coordinator cannot be repopulated by an old-epoch JPEG encode. Delayed-result tests cover replacement, revocation, dismissal, geometry changes, expiry, and the global on-device-only toggle, and assert one stale-discard measurement for each rejected response. In-flight tasks may temporarily retain their own reference data until cancellation completes; clearing the coordinator is not a cryptographic memory-erasure guarantee.

The snapshot API is public, thread-safe and Codable, with a documented export example in `cloud-performance-measurements.md`. It stores metadata, not JPEGs, prompts or credentials. Bridge/debug labels now identify scene-gated frame arrivals and synchronous dispatch duration; these do not establish capture FPS, complete inference latency or speech latency. Camera timestamp conversion explicitly translates host-clock age to the injected Unix clock. Wall-clock adjustment remains a documented measurement limitation.

The proxy retains request/response validation and upload limits. HTTP tests and ledger tests substantiate normal/error/invalid-upload/timeout/disconnect release, concurrent ceiling enforcement, and restart behavior. Reservations deliberately may exceed dispatched calls after disconnect/crash between persistence and transport; they are never refunded. Atomic replacement is not fsync-backed power-loss durability or multi-process locking. SDK abort proves propagation, not that a provider stops billing already accepted work.

An implementation regression was returned for correction: binding the proxy exclusively to `127.0.0.1` broke the existing physical-iPhone/Mac-LAN development setup. The corrected listener defaults to configurable `HOST=0.0.0.0`, restoring direct LAN access; `HOST=127.0.0.1` remains an optional simulator-only setting. Source and operator documentation were re-reviewed after correction.

## Validation evidence

Baseline recorded by the parent: 742 Swift tests / 792 parameterized executions, zero failures/skips; 11 Node tests pass. The full implementation Swift log `/tmp/picpal-architecture-final.log` reports 749 tests in 85 suites / 801 parameterized executions passed (execution count independently confirmed by the coordinating agent through `xcresulttool`; zero failures/skips) and `TEST SUCCEEDED`; its result bundle is `/tmp/picpal-architecture-final.xcresult`. The evaluator inspected this evidence rather than running a competing simulator build.

Swift command recorded in that log:

```sh
xcodebuild test -project PicPal.xcodeproj -scheme PicPal -destination 'platform=iOS Simulator,id=E74AD787-AAEC-4AEB-9AA7-5E65864D4023' -derivedDataPath /tmp/picpal-architecture-derived CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/picpal-architecture-final.xcresult
```

Independent evaluator command:

```sh
node --test proxy/test/*.test.js evals/reference-coaching/evaluate.test.mjs
```

Final independent rerun: **20 passed, 0 failed, 0 skipped**, exit 0, versus 11 baseline passes. The initial sandbox run could not bind localhost (`EPERM`); authorized execution resolved that environment limitation. The final suite includes seven HTTP tests, including a raw-socket incomplete-upload regression. All provider responses were mocked; no paid upstream calls were made.

After review, the engineer strengthened the existing Swift tests to assert comparison suppression during motion and JPEG clearing on replacement. `/tmp/picpal-architecture-review-followup.log` reports 16 tests in two suites passed and `TEST SUCCEEDED` (exit 0). The evaluator inspected those assertions and the completed log. These follow-up changes add assertions, not additional unique Swift test cases; the 749/801 full-suite count remains the appropriate comparison. The test build compiles the simulator app; physical-device build/runtime verification is not claimed.

## Explicit limits and remaining evidence

- Physical-device battery, thermals, capture FPS, local analyzer contention/drop rate, usable-reference coverage, capture-to-save throughput, speech latency, and real-service cloud latency remain unmeasured.
- No production readiness claim: authentication, shared per-user quotas and multi-instance storage remain deferred by the handoff.
The review also identified an incomplete-upload transport cleanup gap. The engineer reproduced it with a raw-socket regression, added close-after-response cleanup for rejected unfinished bodies, and the evaluator independently reran that regression successfully. This finding is resolved.

## Review Summary

No unresolved confident code/security findings remain in the reviewed implementation scope. All handoff acceptance areas have supporting source/test evidence, with the explicit generic-retry spacing clarification above. Device/service measurements and production infrastructure remain intentionally deferred.

| Severity | Count | Status |
|----------|-------|--------|
| CRITICAL | 0 | pass |
| HIGH | 0 | pass |
| MEDIUM | 0 | pass |
| LOW | 0 | pass |

Verdict: **APPROVE** for the scoped development architecture fixes. This approval establishes the tested behavioral/resource improvements, not a measured device-performance or production-readiness claim.
