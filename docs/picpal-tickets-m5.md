# PicPal — M5 Tickets (Scene-Descriptor Caching)

**Companion to**: [picpal-build-order.md](picpal-build-order.md) · [picpal-phase2-launch-prd.md](picpal-phase2-launch-prd.md)
**Date**: 2026-08-11
**Platform**: iOS (Swift 6)
**Sizes**: S ≈ ≤0.5 day · M ≈ 1–2 days · L ≈ 3–5 days (rough, single dev)

> **Milestone target**: Cut redundant VLM API calls by ≥50% on static or slowly-changing scenes without touching the real-time coaching path. All caching is on-device, in-session only — nothing persisted to disk.

## Locked decisions

1. **Cache key: SceneSignature similarity, not exact match** — `SceneSignature.isMateriallyDifferent` already exists and is the right comparator. Cache lookup scans entries for the first non-materially-different match within TTL. O(n) scan over max 20 entries is acceptable.
2. **Cache lives in VLMOrchestrator** — not between `VLMRequestGate` and `VLMOrchestrator`. The gate decides whether to attempt a request; the cache decides whether to fire a network call. Both checks happen inside `VLMOrchestrator.cameraCapture` after the gate passes.
3. **Reference mode calls bypass the cache** — two-image VLM calls (M5.5) carry a reference image and use a different prompt; their responses are not cacheable against single-image signatures. The cache is only consulted when `referenceImage == nil`.
4. **TTL: 30s, max 20 entries** — both named constants; both overridable via TuningSettings in DEBUG builds.
5. **Cache invalidated on background** — `VLMResponseCache.invalidate()` is called when the app goes to background, alongside the existing telemetry export, so a resumed session starts fresh.

## Conventions (carried from M0–M4)

- Swift 6 strict concurrency; `OSAllocatedUnfairLock` for shared mutable state.
- **Swift Testing only** (`import Testing`), ≥80% coverage on new logic.
- 300-line file limit; no magic numbers (named `static` constants).
- Immutable value snapshots — `VLMResponseCache` entries are value types.

## Execution order

```
M5-0 (VLMResponseCache type — pure, no deps)
  ↓
M5-1 (wire into VLMOrchestrator + telemetry)
```

---

## M5-0 — VLMResponseCache
**Size**: S · **Deps**: none

**Goal**: An in-session, on-device LRU cache mapping `SceneSignature` fingerprints to `AestheticSignal` responses. Pure type — no I/O, no UIKit, fully injectable clock for testing.

**File**: `picpal/Sources/VLM/VLMResponseCache.swift`

```swift
import Foundation

/// In-session VLM response cache. On-device only; never persisted.
/// Keyed by SceneSignature similarity (not exact match).
final class VLMResponseCache: @unchecked Sendable {

    static let defaultMaxEntries: Int = 20
    static let defaultTTLSeconds: Double = 30.0

    struct Entry: Sendable {
        let signature: SceneSignature
        let signal: AestheticSignal
        let timestamp: Date
    }

    private let lock: OSAllocatedUnfairLock<[Entry]>
    private let maxEntries: Int
    private let ttlSeconds: Double
    private let clock: @Sendable () -> Date

    init(
        maxEntries: Int = defaultMaxEntries,
        ttlSeconds: Double = defaultTTLSeconds,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lock = OSAllocatedUnfairLock(initialState: [])
        self.maxEntries = maxEntries
        self.ttlSeconds = ttlSeconds
        self.clock = clock
    }

    /// Returns a cached AestheticSignal if a non-materially-different,
    /// non-expired entry exists; nil otherwise.
    func lookup(for signature: SceneSignature) -> AestheticSignal? {
        let now = clock()
        return lock.withLock { entries in
            entries.first(where: { entry in
                !entry.signature.isMateriallyDifferent(from: signature) &&
                now.timeIntervalSince(entry.timestamp) < ttlSeconds
            })?.signal
        }
    }

    /// Stores a response for a given signature.
    /// Moves existing same-signature entries to front (LRU refresh).
    /// Drops the tail entry when at capacity.
    func store(_ signal: AestheticSignal, for signature: SceneSignature) {
        let entry = Entry(signature: signature, signal: signal, timestamp: clock())
        lock.withLock { entries in
            entries.removeAll { !$0.signature.isMateriallyDifferent(from: signature) }
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast()
            }
        }
    }

    /// Clears all entries. Call on app background / session end.
    func invalidate() {
        lock.withLock { $0.removeAll() }
    }

    /// Current entry count. For telemetry / testing.
    var count: Int {
        lock.withLock { $0.count }
    }
}
```

**Acceptance criteria**

- [ ] `lookup` returns `nil` before any `store` call.
- [ ] `lookup` returns the cached signal when the signature is not materially different from the stored one.
- [ ] `lookup` returns `nil` after TTL has elapsed (verified with injectable clock).
- [ ] `store` replaces an existing same-signature entry rather than duplicating it (count stays ≤ 1 per unique signature cluster).
- [ ] When `maxEntries` is exceeded, the oldest entry is dropped (LRU tail eviction).
- [ ] `invalidate` removes all entries; subsequent `lookup` returns `nil`.
- [ ] All constants are named (`defaultMaxEntries`, `defaultTTLSeconds`); no bare literals.
- [ ] Thread-safe: concurrent `store` + `lookup` calls do not crash or corrupt state.
- [ ] Unit tests: `VLMResponseCacheTests.swift` — cover nil-before-store, hit, expired-miss, eviction, invalidate, concurrency (two simultaneous stores + lookup).

---

## M5-1 — Wire cache into VLMOrchestrator + telemetry
**Size**: M · **Deps**: M5-0

**Goal**: Integrate the cache into the VLM call path so that cache hits short-circuit the network call; extend `TelemetrySnapshot` with hit/miss counts so the ≥50% reduction KPI is measurable.

### VLMOrchestrator changes

Read `picpal/Sources/VLM/VLMOrchestrator.swift` before touching it. The cache is consulted **after** the request gate passes and **before** `FrameEncoder.encode` runs:

```swift
// Inside VLMOrchestrator.cameraCapture (after existing guards)
if let cached = responseCache.lookup(for: currentSignature) {
    onAestheticSignal?(cached)
    sessionStats.recordCacheHit()
    return
}
// ... existing encode → request path ...
// On successful response:
responseCache.store(aestheticSignal, for: currentSignature)
sessionStats.recordCacheMiss()
```

**`VLMOrchestrator` gains**:
- `private let responseCache: VLMResponseCache` — injected at init (default: `VLMResponseCache()`).
- `private var sessionStats: VLMSessionStats` — lightweight counter (hits, misses, requests).
- `func invalidateCache()` — calls `responseCache.invalidate()`; called from `ContentView+Session` on background transition.
- In DEBUG builds only: `TuningSettings.shared.vlmCacheTTLSeconds` and `vlmCacheMaxEntries` added to `TuningSettings` and wired to the injected cache. This requires reading `TuningSettings.swift` to add the two properties and updating `TuningPanel.swift` to show them in the "VLM" section.

### TuningSettings additions (`#if DEBUG`, `picpal/Sources/App/TuningSettings.swift`)

```swift
var vlmCacheTTLSeconds: Double {
    get { stored(Keys.vlmCacheTTL, default: VLMResponseCache.defaultTTLSeconds) }
    set { UserDefaults.standard.set(newValue, forKey: Keys.vlmCacheTTL) }
}
var vlmCacheMaxEntries: Int {
    get {
        let v = UserDefaults.standard.integer(forKey: Keys.vlmCacheMaxEntries)
        return v > 0 ? v : VLMResponseCache.defaultMaxEntries
    }
    set { UserDefaults.standard.set(newValue, forKey: Keys.vlmCacheMaxEntries) }
}
```

Add both keys to `resetToDefaults()`.

### TelemetrySnapshot extension (`picpal/Sources/Telemetry/TelemetryExporter.swift`)

Add two fields (backward-compatible, defaults nil):

```swift
public let vlmCacheHits: Int?       // nil if cache not wired
public let vlmCacheMisses: Int?     // nil if cache not wired
```

`exportSnapshot` in `ContentView+Session.swift` populates these from `vlmOrchestrator?.sessionStats`.

### ContentView+Session changes

- Call `vlmOrchestrator?.invalidateCache()` in the `.background` scenePhase handler (alongside `settleEventTimer?.reset()`).

**Acceptance criteria**

- [ ] When the same scene is stable for >8s (second gate pass), the second VLM call is served from cache — no network request fires. Verified in unit test via mock `VLMClient` that counts calls.
- [ ] Cache is not consulted when `referenceImage != nil` (reference-mode calls always go to network — verified in unit test).
- [ ] `vlmCacheHits` and `vlmCacheMisses` in the exported `TelemetrySnapshot` JSON are non-nil and sum to total VLM gate passes.
- [ ] `invalidateCache()` is called on app background; the cache entry count drops to 0 (verified in `ContentView+Session` tests).
- [ ] In DEBUG: `TuningPanel` shows "Cache TTL" and "Max entries" steppers in the "VLM" section; modifying them and relaunching the app applies the new values.
- [ ] All new keys in `TuningSettings` follow the `com.picpal.tuning.*` naming convention and are removed by `resetToDefaults()`.
- [ ] Unit tests: `VLMOrchestratorCacheTests.swift` — cache-hit short-circuits mock client, reference-mode bypasses cache, cache invalidated on background call.
- [ ] `TelemetrySnapshot` encodes with new optional fields; existing tests still compile.
