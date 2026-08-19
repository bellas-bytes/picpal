## M5-1 Report — Wire VLMResponseCache into VLMOrchestrator + telemetry

**Status**: DONE  
**Commit**: `759398f feat(m5-1): wire VLMResponseCache into VLMOrchestrator + telemetry`  
**Branch**: `feature/m5-caching`

---

### What was done

#### New files
- `picpal/Sources/VLM/VLMSessionStats.swift` — defines `VLMSessionStats` (hit/miss counter struct), `VLMOrchestratorConstants` (moved from orchestrator), and `VLMFailureState` (renamed from `FailureState`, moved from orchestrator). Moving these out kept `VLMOrchestrator.swift` at ~290 lines.
- `picpal/Tests/PicPalTests/VLMOrchestratorCacheTests.swift` — 5 acceptance-criteria tests, all passing.

#### Modified files
- **VLMOrchestrator.swift** — cache wired in (lookup after gate, before isBusy; store after suppressor-passed signal); `responseCache`, `statsLock`, `referenceImageLock` properties added; `sessionStats`, `referenceImage`, `invalidateCache()` API added; `VLMOrchestratorConstants` and `VLMFailureState` references updated; init `public` modifier dropped (all callers are same-module or `@testable import`).
- **TuningSettings.swift** (`#if DEBUG`) — `vlmCacheTTLSeconds` and `vlmCacheMaxEntries` properties added under `com.picpal.tuning.*` keys; both removed by `resetToDefaults()`.
- **TuningPanel.swift** (`#if DEBUG`) — "Cache TTL" and "Max entries" steppers added in "VLM" section; range constants in `TuningRanges`; reset button reloads both state vars.
- **TelemetryExporter.swift** — `vlmCacheHits: Int?` and `vlmCacheMisses: Int?` added to `TelemetrySnapshot` with backward-compatible `nil` defaults.
- **ContentView+Session.swift** — `vlmOrchestrator?.invalidateCache()` called in `.background` handler; `exportSnapshot` populates `vlmCacheHits`/`vlmCacheMisses` from `vlmOrchestrator?.sessionStats`.
- **PicPal.xcodeproj/project.pbxproj** — regenerated via `xcodegen generate` to include the new `VLMSessionStats.swift` source file.

---

### Test results

`** TEST SUCCEEDED **` — all suite tests pass.

New tests in `VLMOrchestratorCacheTests`:
| Test | Result | Duration |
|------|--------|----------|
| cache hit on returning scene skips VLM client call | PASS | 0.91s |
| cache hit with valid cached remark bypasses VLM client | PASS | 0.67s |
| reference mode bypasses cache — VLM always called | PASS | 0.91s |
| invalidateCache drops all entries; subsequent frames reach VLM client | PASS | 0.32s |
| sessionStats accurately tracks hits and misses | PASS | 0.67s |

All pre-existing tests continue to pass.

---

### Acceptance criteria status

- [x] Cache hit short-circuits mock client — verified via `cacheHitWithRemark_bypassesClient` (Test 1b) and `sessionStats_tracksHitsAndMisses` (Test 4)
- [x] Reference-mode bypasses cache — verified via `referenceMode_bypassesCache` (Test 2)
- [x] `vlmCacheHits`/`vlmCacheMisses` in exported snapshot are non-nil when orchestrator is wired
- [x] `invalidateCache()` called on `.background`; entries drop to 0 — verified via `invalidateCache_dropsAllEntries` (Test 3)
- [x] DEBUG TuningPanel shows "Cache TTL" and "Max entries" steppers in VLM section
- [x] All TuningSettings keys follow `com.picpal.tuning.*`; removed by `resetToDefaults()`
- [x] `TelemetrySnapshot` encodes with new optional fields; existing tests compile and pass

---

### Concerns

**Init access level change**: The `VLMOrchestrator.init` was demoted from `public` to `internal` to allow the `responseCache: VLMResponseCache = VLMResponseCache()` default parameter (Swift 6 prohibits a `public` init from referencing internal types in default values). All callers are either in the same module (`ContentView+Session.swift`) or in tests using `@testable import PicPal`. The class itself remains `public`; only the designated init's access level changed. No external callers exist in the current codebase.

**`xcodegen generate` required for new source file**: `VLMSessionStats.swift` is a new source file that required running `xcodegen generate` before the build picked it up. Future new source files in this project will need the same step.

**`sessionStats.cacheMisses` counts only suppressor-passing signals, not all gate passes**: A gate-passing frame that produces a `NOTHING_TO_SAY` response (discarded by the suppressor) does not increment `cacheMisses`. So `hits + misses` counts valid aesthetic signals rather than raw gate passes. This is consistent with the brief's cache-store placement (after `onAestheticSignal(valid)`) and produces sensible telemetry, though the sum is not exactly "total gate passes" as the brief's acceptance criterion loosely states.

---

### Post-Implementation Fix — Test 1 Hollow Assertion (M5-1)

**Issue**: Test 1 (`cacheHit_shortCircuitsClient`) read `client.callCount` but never asserted on it. The root cause: `CountingVLMClient` returns `NOTHING_TO_SAY`, which `StaleSuppressor` discards, preventing cache storage and cache hits. The test could not verify its acceptance criterion ("cache hit on returning scene skips VLM client call").

**Fix** (commit `c054df9`):
1. Removed Test 1 entirely (no meaningful assertion).
2. Promoted Test 1b to Test 1 (renamed test section marker; function `cacheHitWithRemark_bypassesClient` unchanged).
3. Added `callCount` property to `InstantVLMClient` (converted from struct to class with `OSAllocatedUnfairLock<Int>`; incremented in `analyze(_)`).
4. Added assertion in Test 1 after cache-hit frame: `#expect(client.callCount == 2)` — verifies that the third frame (returning to scene A) does NOT invoke the client (cache hit).

**Test results**: All 4 VLMOrchestratorCacheTests pass; cache-hit path confirmed verified.

| Test | Result | Duration |
|------|--------|----------|
| cache hit with valid cached remark bypasses VLM client | PASS | 0.679s |
| reference mode bypasses cache — VLM always called | PASS | 0.906s |
| invalidateCache drops all entries; subsequent frames reach VLM client | PASS | 0.303s |
| sessionStats accurately tracks hits and misses | PASS | 0.657s |

---

## Whole-Branch Review Fix-Wave — Important Findings (2026-08-17)

### What was changed

**Finding 1 — Cache tuning params now applied in wireUp()**
- `picpal/Sources/App/ContentView+Session.swift`, after line 170 (after the vlmGate `#if DEBUG` block):
  - Added `#if DEBUG` / `#else` block constructing `vlmCache` from `TuningSettings.shared.vlmCacheMaxEntries` and `TuningSettings.shared.vlmCacheTTLSeconds`.
  - Passed `responseCache: vlmCache` as an explicit argument to `VLMOrchestrator(...)`.

**Finding 2 — cacheMisses now counted at actual cache miss**
- `picpal/Sources/VLM/VLMOrchestrator.swift`, line ~196 (after the cache lookup block, step 3b):
  - Added `statsLock.withLock { $0.recordCacheMiss() }` immediately after the cache-lookup block exits without a hit.
- `picpal/Sources/VLM/VLMOrchestrator.swift`, former step 5f (~line 291):
  - Removed `statsLock.withLock { $0.recordCacheMiss() }` from the success path. Cache store at 5f is unchanged.
  - Updated the step-5f comment to reflect that only emit + store remain there.

**Finding 3 — init access level documented**
- `picpal/Sources/VLM/VLMOrchestrator.swift`, line ~111 (above `init(`):
  - Added one-line comment: `// Internal: VLMResponseCache default parameter prevents public init under Swift 6 access rules.`

### Test output

`** TEST SUCCEEDED **` — 475 tests in 55 suites passed after 7.350 seconds. No regressions.
