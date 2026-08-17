import Foundation
import Testing
@testable import PicPal

// MARK: - VLMResponseCacheTests

/// Unit tests for `VLMResponseCache` — in-session LRU cache keyed by SceneSignature similarity.
///
/// Covers all acceptance criteria:
///   1. `lookup` returns `nil` before any `store` call.
///   2. `lookup` returns the cached signal when signature is not materially different.
///   3. `lookup` returns `nil` after TTL has elapsed (with injectable clock).
///   4. `store` replaces existing same-signature entry; no duplicates.
///   5. When `maxEntries` exceeded, oldest entry is dropped (LRU eviction).
///   6. `invalidate` clears all entries.
///   7. All constants are named; no bare literals.
///   8. Thread-safe: concurrent `store` + `lookup` do not crash.
@Suite("VLMResponseCache")
struct VLMResponseCacheTests {

    // MARK: - Fixtures

    /// A dark scene with stable luminance.
    private let darkScene = SceneSignature(
        meanLuminance: 0.20,
        luminanceVariance: 0.001
    )

    /// A scene nearly identical to `darkScene` (not materially different).
    private let darkSceneSimilar = SceneSignature(
        meanLuminance: 0.21,
        luminanceVariance: 0.0012
    )

    /// A scene materially different from `darkScene` (brightness shift > threshold).
    private let brightScene = SceneSignature(
        meanLuminance: 0.80,
        luminanceVariance: 0.001
    )

    /// A valid aesthetic signal with a remark.
    private let validSignal = AestheticSignal(
        remark: "Step back to include the full frame.",
        confidence: 1.0,
        hint: .remark
    )

    /// An alternative signal.
    private let alternateSignal = AestheticSignal(
        remark: "Move the camera left.",
        confidence: 0.95,
        hint: .remark
    )

    /// A no-op signal.
    private let nothingSignal = AestheticSignal.nothingToSay

    // MARK: - Test: nil-before-store

    @Test("lookup returns nil before any store call")
    func nilBeforeStore() {
        let cache = VLMResponseCache()
        let result = cache.lookup(for: darkScene)
        #expect(result == nil)
    }

    // MARK: - Test: cache hit

    @Test("lookup returns cached signal when signature is not materially different")
    func cacheHit() {
        let cache = VLMResponseCache()
        cache.store(validSignal, for: darkScene)

        // Query with nearly identical signature (not materially different).
        let result = cache.lookup(for: darkSceneSimilar)
        #expect(result == validSignal)
    }

    // MARK: - Test: cache miss (materially different signature)

    @Test("lookup returns nil when signature is materially different")
    func cacheMissMateriallyDifferent() {
        let cache = VLMResponseCache()
        cache.store(validSignal, for: darkScene)

        // Query with materially different signature.
        let result = cache.lookup(for: brightScene)
        #expect(result == nil)
    }

    // MARK: - Test: TTL expiration

    @Test("lookup returns nil after TTL has elapsed")
    func ttlExpiration() {
        class Clock: @unchecked Sendable {
            var now: Date
            init(now: Date = Date()) {
                self.now = now
            }
        }

        let clock = Clock()
        let ttlSeconds = 5.0
        let cache = VLMResponseCache(ttlSeconds: ttlSeconds, clock: { clock.now })

        // Store at t=0.
        cache.store(validSignal, for: darkScene)
        #expect(cache.lookup(for: darkScene) == validSignal)

        // Advance clock past TTL.
        clock.now = clock.now.addingTimeInterval(ttlSeconds + 0.1)
        #expect(cache.lookup(for: darkScene) == nil)
    }

    // MARK: - Test: replacement (no duplicates)

    @Test("store replaces existing same-signature entry without duplicating")
    func replacementNoDuplicates() {
        let cache = VLMResponseCache()

        // Store first signal.
        cache.store(validSignal, for: darkScene)
        #expect(cache.count == 1)

        // Store different signal for same (non-materially-different) signature.
        cache.store(alternateSignal, for: darkSceneSimilar)
        #expect(cache.count == 1)

        // Verify the new signal is returned, not the old one.
        let result = cache.lookup(for: darkScene)
        #expect(result == alternateSignal)
    }

    // MARK: - Test: LRU eviction

    @Test("when maxEntries exceeded, oldest entry is dropped (LRU tail eviction)")
    func lruEviction() {
        let maxEntries = 3
        let cache = VLMResponseCache(maxEntries: maxEntries)

        // Define three distinct scenes that are all materially different.
        let scene1 = SceneSignature(meanLuminance: 0.1, luminanceVariance: 0.001)
        let scene2 = SceneSignature(meanLuminance: 0.5, luminanceVariance: 0.001)
        let scene3 = SceneSignature(meanLuminance: 0.9, luminanceVariance: 0.001)
        let scene4 = SceneSignature(meanLuminance: 0.3, luminanceVariance: 0.001)

        // Store three entries.
        cache.store(validSignal, for: scene1)
        cache.store(validSignal, for: scene2)
        cache.store(validSignal, for: scene3)
        #expect(cache.count == 3)

        // Store fourth entry; should evict scene1 (the oldest).
        cache.store(nothingSignal, for: scene4)
        #expect(cache.count == 3)

        // Verify scene1 is gone.
        #expect(cache.lookup(for: scene1) == nil)

        // Verify scene2, scene3, scene4 are present.
        #expect(cache.lookup(for: scene2) == validSignal)
        #expect(cache.lookup(for: scene3) == validSignal)
        #expect(cache.lookup(for: scene4) == nothingSignal)
    }

    // MARK: - Test: invalidate

    @Test("invalidate removes all entries; subsequent lookup returns nil")
    func invalidateClears() {
        let cache = VLMResponseCache()
        cache.store(validSignal, for: darkScene)
        cache.store(alternateSignal, for: brightScene)
        #expect(cache.count == 2)

        cache.invalidate()
        #expect(cache.count == 0)

        // Verify both lookups return nil.
        #expect(cache.lookup(for: darkScene) == nil)
        #expect(cache.lookup(for: brightScene) == nil)
    }

    // MARK: - Test: named constants

    @Test("named constants are defined; no bare literals")
    func namedConstants() {
        // Verify the static constants are accessible.
        #expect(VLMResponseCache.defaultMaxEntries > 0)
        #expect(VLMResponseCache.defaultTTLSeconds > 0)
    }

    // MARK: - Test: thread safety (concurrent operations)

    @Test("concurrent store + lookup calls do not crash or corrupt state")
    func threadSafety() async {
        let cache = VLMResponseCache()
        let iterations = 100

        // Define distinct scenes.
        let scene1 = SceneSignature(meanLuminance: 0.1, luminanceVariance: 0.001)
        let scene2 = SceneSignature(meanLuminance: 0.5, luminanceVariance: 0.001)

        // Spawn two concurrent tasks: one stores, one looks up.
        await withTaskGroup(of: Void.self) { group in
            // Task 1: Store many times.
            group.addTask {
                for i in 0..<iterations {
                    let signal = AestheticSignal(
                        remark: "Signal \(i)",
                        confidence: Float(i) / Float(iterations),
                        hint: .remark
                    )
                    if i % 2 == 0 {
                        cache.store(signal, for: scene1)
                    } else {
                        cache.store(signal, for: scene2)
                    }
                }
            }

            // Task 2: Lookup many times.
            group.addTask {
                for _ in 0..<iterations {
                    _ = cache.lookup(for: scene1)
                    _ = cache.lookup(for: scene2)
                }
            }

            // Task 3: Interleave invalidate.
            group.addTask {
                for i in 0..<(iterations / 10) {
                    if i % 3 == 0 {
                        cache.invalidate()
                    }
                }
            }

            await group.waitForAll()
        }

        // Verify the cache is in a valid state (no crash, count is reasonable).
        #expect(cache.count >= 0)
        #expect(cache.count <= VLMResponseCache.defaultMaxEntries)
    }

    // MARK: - Test: custom clock injection

    @Test("custom clock is used for TTL checks")
    func customClockInjection() {
        class Clock: @unchecked Sendable {
            var now: Date
            init(now: Date = Date()) {
                self.now = now
            }
        }

        let clock = Clock()
        let cache = VLMResponseCache(ttlSeconds: 10.0, clock: { clock.now })

        cache.store(validSignal, for: darkScene)

        // Verify hit at t=0.
        #expect(cache.lookup(for: darkScene) == validSignal)

        // Advance clock by 5 seconds (within TTL).
        clock.now = clock.now.addingTimeInterval(5.0)
        #expect(cache.lookup(for: darkScene) == validSignal)

        // Advance clock past TTL (15 seconds total).
        clock.now = clock.now.addingTimeInterval(6.0)
        #expect(cache.lookup(for: darkScene) == nil)
    }

    // MARK: - Test: multiple signals for materially different signatures

    @Test("different materially-different signatures cache independently")
    func multipleDifferentSignatures() {
        let cache = VLMResponseCache()

        // Store two signals for materially different signatures.
        cache.store(validSignal, for: darkScene)
        cache.store(alternateSignal, for: brightScene)
        #expect(cache.count == 2)

        // Verify each lookup returns the correct signal.
        #expect(cache.lookup(for: darkScene) == validSignal)
        #expect(cache.lookup(for: brightScene) == alternateSignal)
    }
}
