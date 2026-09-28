# Architecture fixes implementation report

Date: 2026-09-24. Baseline: working tree archived at `/tmp/picpal-architecture-baseline-20260924.tar.gz`, including existing user edits; Git HEAD is not the baseline. No commit or public deployment performed.

## Delivered changes

- Cache delivery separates non-consuming eligibility from transport spending. Exhausted network quota does not disable cached guidance; delivery still records novelty/cadence. Every real client attempt, including retries, spends one unit; encoding failure and queued context invalidation spend zero. Live scene signature is computed once per received frame.
- Consented reference profiles prepare immediately without a live frame or settled motion. The profile uploads only the reference. Reference JPEGs are memoized in memory per consented identity, retained across geometry revisions, cleared by replacement/revocation, and protected against stale worker repopulation. `CIContext` is reused. Comparison freshness and motion protections remain.
- Auto-capture armed state reaches the orchestrator through the composition root. Armed reference renewal uses the earliest eligible eight-second dispatch; disarming restores twenty-second sparse idle refresh. This approaches 7.5 calls/minute, not a hard three-call/minute cap.
- Public Codable `sessionStats` provides bounded (128 records) request metadata, encoding duration, translated capture timestamps, actual async completion, cache flags, attempts, accepted results and stale discards. Debug bridge labels describe scene-gated arrival and synchronous dispatch. See [measurement contract](cloud-performance-measurements.md).
- Proxy globally bounds admissions before upload allocation, aborts timed-out/disconnected work, disables hidden retries, serializes asynchronous atomic quota persistence, fails closed on corruption/write failure and retains the persistent 200 ceiling. Error responses close unfinished uploads. Default LAN binding is preserved with configurable `HOST`. See [operator guide](../proxy/README.md).

## Changed files relative to archived source

Swift production: `VLMRequestGate.swift`, `VLMOrchestrator.swift`, `VLMClient.swift`, `FrameEncoder.swift`, `ReferenceAnalysisCoordinator.swift`, `VLMSessionStats.swift`, `ContentView.swift`, `ContentView+Session.swift`, `DebugOverlayView.swift`, `PipelineTelemetryBridge.swift`, `TelemetryExporter.swift`.

Swift tests: `VLMOrchestratorCacheTests.swift`, `VLMOrchestratorRetryTests.swift`, `ReferenceVLMTests.swift`, `ReferenceAnalysisCoordinatorTests.swift` (new telemetry suite lives in existing cache test file).

Proxy: `index.js`, new `app.js`, `resources.js`, `README.md`, `test/app.test.js`, `test/resources.test.js`. Documentation: this report, `cloud-performance-measurements.md`, and cadence clarification in project-manager handoff. Existing package/reference schema work was preserved.

## Verification

Baseline Swift: **742 passed**, 792 parameterized executions, zero failed/skipped. Baseline Node: **11 passed**.

Initial cache/profile regression run: **12 tests, 6 expected issues**. Seeded cache delivery incorrectly consumed quota or vanished with exhausted quota; immediate moving-phone profile did not dispatch. Log `/tmp/picpal-architecture-red.log`. New telemetry API tests initially failed compilation because the API was absent; `/tmp/picpal-architecture-telemetry-red.log`.

Focused implementation run: **40 tests across 6 suites passed**, exit 0; `/tmp/picpal-architecture-focused.log`.

Full Swift verification:

```sh
xcodebuild test -project PicPal.xcodeproj -scheme PicPal \
  -destination 'platform=iOS Simulator,id=E74AD787-AAEC-4AEB-9AA7-5E65864D4023' \
  -derivedDataPath /tmp/picpal-architecture-derived CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /tmp/picpal-architecture-final.xcresult
```

**749 tests across 85 suites passed**, 801 parameterized executions, zero failed/skipped; exit 0, app built successfully. iPhone 17 Pro, simulator iOS 26.3.1. Summary verified using `xcrun xcresulttool get test-results summary --path /tmp/picpal-architecture-final.xcresult`. Full output: `/tmp/picpal-architecture-final.log`.

Node after resource hardening: `node --test proxy/test/*.test.js evals/reference-coaching/evaluate.test.mjs` — **20 passed**, exit 0; `/tmp/picpal-proxy-final.log`. New partial rejected-upload regression first failed because the socket stayed open, then passed after cleanup (`/tmp/picpal-proxy-hardening-red.log`). Tests use local mocked upstream, no paid API calls. `node --check proxy/index.js` passes.

Review follow-up adds assertions that moving phones cannot dispatch comparisons and replacing a reference clears memoized bytes. Targeted suites use the full Swift command without the result bundle and with `-only-testing:PicPalTests/VLMOrchestratorCacheTests -only-testing:PicPalTests/ReferenceAnalysisCoordinatorTests`; output `/tmp/picpal-architecture-review-followup.log`. **16 tests in two suites passed**, exit 0. These are test-only changes after the full Swift run.

## Substantiated improvements and limits

Integration tests establish cache-hit budget delta **1 → 0**, including exhausted quotas; profile live encodes **1 → 0**; reference encodes **per request → 1 across profile plus two comparisons**. Source inspection establishes signature computations **2 → 1** per generic frame. Proxy tests demonstrate configured admission bounds, no ceiling overspend, abort/resource release, restart persistence, fail-closed corruption/write errors, and no synchronous request-path file writes.

Intentional policy clarifications: a profile uses the existing ten-second service timeout rather than eight-second live evidence validity (expiry fixture advances to 111 from start 100). Comparisons remain strictly eight seconds. The existing bounded generic retries retain one-second then two-second backoff as an explicit exception to eight-second **new-analysis/reference** dispatch cadence, each charged. Reference requests have no automatic retries.

Not established: lower real-service latency, device FPS, battery/thermal improvement, continuous reference readiness, faster speech or photo throughput. Those need physical-device/service profiling. Proxy ledger remains single-process and lacks fsync power-loss guarantees; reservations conservatively count cancellations after persistence. Aborting a request cannot undo provider work already accepted. Capture/save transaction and diagnostic inference remain unchanged.
