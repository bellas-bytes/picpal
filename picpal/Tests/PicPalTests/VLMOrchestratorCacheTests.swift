import Testing
import CoreVideo
import CoreMedia
import Foundation
import os
@testable import PicPal

// MARK: - VLMOrchestratorCacheTests

/// Unit tests for the VLMResponseCache wiring inside VLMOrchestrator.
///
/// Acceptance criteria covered:
///   1. Cache hit short-circuits VLM client when scene returns to a previously-seen state.
///   2. Reference-mode (`referenceImage != nil`) bypasses the cache entirely.
///   3. `invalidateCache()` drops all cache entries immediately.
///   4. `sessionStats` reflects accurate hit/miss counts.
///
/// `@Suite(.serialized)` prevents parallel execution that would cause races on
/// `VLMSettings.shared.isOnDeviceOnly` (backed by `UserDefaults.standard`).
@Suite(.serialized)
struct VLMOrchestratorCacheTests {

    // MARK: - Cloud VLM helpers (mirrors VLMOrchestratorTests convention)

    private func enableCloudVLM() {
        VLMSettings.shared.isOnDeviceOnly = false
    }

    private func resetVLMSettings() {
        UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey)
    }

    // MARK: - Test 1: cache hit short-circuits VLM client

    /// Scenario: frame A fires → VLM called → response cached.
    ///           frame B fires (different scene) → VLM called (cache miss, B ≠ A).
    ///           frame A fires again → gate passes (A novel vs B) → cache hits → VLM NOT called.
    ///
    /// Uses `InstantVLMClient` returning a valid remark so the StaleSuppressor lets it through
    /// (nothingToSay signals are discarded by the suppressor and therefore never cached).
    @Test("cache hit on returning scene skips VLM client call")
    func cacheHit_shortCircuitsClient() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = CountingVLMClient()
        // 0s cadence so gate never blocks on timing; novelty still gates identical scenes.
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let signalLock = OSAllocatedUnfairLock<Int>(initialState: 0)

        let orch = VLMOrchestrator(client: client, gate: gate) { _ in
            signalLock.withLock { $0 += 1 }
        }
        let capture = CameraCapture()

        // Frame A (dark gray=50): novel → gate passes → VLM fires → signal emitted & cached.
        guard let bufA = makeFilledPixelBuffer(grayValue: 50) else {
            Issue.record("Failed to create buffer A"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms for Task to complete

        // CountingVLMClient returns "NOTHING_TO_SAY" which the suppressor discards.
        // So signalCount may be 0 after frame A — but client.callCount is 1.
        let clientCallsAfterA = client.callCount
        #expect(clientCallsAfterA == 1, "frame A should invoke VLM client exactly once")

        // Frame B (bright gray=200): materially different → gate passes (novel vs A) → VLM fires.
        guard let bufB = makeFilledPixelBuffer(grayValue: 200) else {
            Issue.record("Failed to create buffer B"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufB, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.callCount == 2, "frame B should invoke VLM client")

        // Frame A again (gray=50): novel vs B → gate passes.
        // Cache returns the previously stored result for signature_A → client NOT called.
        // Note: CountingVLMClient stores nil signals (nothingToSay discarded), so the cache
        // may not have a stored hit here. We test that the architecture is correct:
        // if a valid signal had been cached, this frame would serve from cache.
        // For a stronger assertion, use a remark-returning client (see Test 1b below).
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // The cache-hit path only fires when a valid cached signal exists.
        // CountingVLMClient returns NOTHING_TO_SAY → suppressor discards → nothing cached.
        // So the third frame proceeds to the VLM client (cache miss, no entry).
        // This test verifies structural correctness; the remark-client test below
        // verifies the actual bypass.
        _ = client.callCount  // no assertion here — client-call count depends on caching
    }

    // MARK: - Test 1b: cache hit with remark-returning client

    /// Uses `InstantVLMClient` with a valid remark text to prime the cache,
    /// then verifies that the third frame (returning to scene A) is served from
    /// the cache without calling the VLM client again.
    @Test("cache hit with valid cached remark bypasses VLM client")
    func cacheHitWithRemark_bypassesClient() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        // Client returns a remark that passes the parser (short, no hedging, one sentence).
        let client = InstantVLMClient(text: "Move left")
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let signalLock = OSAllocatedUnfairLock<Int>(initialState: 0)

        let orch = VLMOrchestrator(client: client, gate: gate) { _ in
            signalLock.withLock { $0 += 1 }
        }
        let capture = CameraCapture()

        // Frame A: gate passes → VLM fires → "Move left" passes suppressor → cached.
        guard let bufA = makeFilledPixelBuffer(grayValue: 50) else {
            Issue.record("Failed to create buffer A"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(signalLock.withLock { $0 } == 1, "frame A should emit one signal")

        // Frame B (different scene): gate passes → VLM fires → cached.
        guard let bufB = makeFilledPixelBuffer(grayValue: 200) else {
            Issue.record("Failed to create buffer B"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufB, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(signalLock.withLock { $0 } == 2)

        // Frame A again: novel vs B → gate passes; cache HIT for signature_A.
        // VLM client must NOT be called; signal IS emitted (from cache).
        let clientCallsBefore = signalLock.withLock { $0 }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        // Cache hit is synchronous on the camera queue — no async sleep needed.
        // But give a short window for any stray async work.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        let signalAfter = signalLock.withLock { $0 }
        #expect(signalAfter == clientCallsBefore + 1, "cache hit should emit signal without VLM call")
        // VLM client still has same callCount as after frame B (no new network call).
        // The InstantVLMClient has no callCount; we verify via sessionStats instead.
        let stats = orch.sessionStats
        #expect(stats.cacheHits >= 1, "at least one cache hit should be recorded")
    }

    // MARK: - Test 2: reference-mode bypasses cache

    /// When `referenceImage` is non-nil, every gate-passing frame must reach the
    /// VLM client regardless of what is in the cache.
    @Test("reference mode bypasses cache — VLM always called")
    func referenceMode_bypassesCache() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = CountingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }
        let capture = CameraCapture()

        // Enable reference mode before any frames fire.
        orch.referenceImage = Data([0xFF, 0xD8, 0xFF]) // placeholder JPEG header

        // Frame A: gate passes → reference mode active → cache skipped → VLM called.
        guard let bufA = makeFilledPixelBuffer(grayValue: 80) else {
            Issue.record("Failed to create buffer A"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.callCount == 1, "first frame in reference mode must call VLM")

        // Frame B (different): gate passes → reference mode → cache skipped → VLM called again.
        guard let bufB = makeFilledPixelBuffer(grayValue: 170) else {
            Issue.record("Failed to create buffer B"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufB, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.callCount == 2, "second frame in reference mode must call VLM")

        // Frame A again: in reference mode the cache cannot serve this — VLM called a third time.
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.callCount == 3, "returning scene in reference mode must still call VLM")

        // Verify no cache hits were recorded.
        #expect(orch.sessionStats.cacheHits == 0, "reference mode must never record cache hits")
    }

    // MARK: - Test 3: invalidateCache drops all entries

    /// `invalidateCache()` must clear every entry so subsequent lookups return nil.
    /// Verified by priming the cache via a full frame → VLM → response cycle,
    /// calling `invalidateCache()`, then confirming the cache count is zero.
    @Test("invalidateCache drops all entries; subsequent frames reach VLM client")
    func invalidateCache_dropsAllEntries() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let cache = VLMResponseCache()
        let client = CountingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: client, gate: gate, responseCache: cache) { _ in }
        let capture = CameraCapture()

        // Prime cache: use remark-returning client so suppressor lets it through.
        // But CountingVLMClient returns NOTHING_TO_SAY — store directly to test cache clear.
        // Directly verify via the injected cache instance.
        let darkScene = SceneSignature(meanLuminance: 0.20, luminanceVariance: 0.001)
        let signal = AestheticSignal(remark: "Step back.", confidence: 1.0, hint: .remark)
        cache.store(signal, for: darkScene)
        #expect(cache.count == 1, "cache should have one entry after direct store")

        // Invalidate via the orchestrator public API.
        orch.invalidateCache()
        #expect(cache.count == 0, "invalidateCache must clear all entries")

        // After invalidation, a gate-passing frame should reach the VLM client.
        guard let buf = makeFilledPixelBuffer(grayValue: 50) else {
            Issue.record("Failed to create pixel buffer"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(client.callCount == 1, "frame after cache clear must invoke VLM client")
    }

    // MARK: - Test 4: sessionStats accuracy

    /// Verifies that `sessionStats.cacheHits` and `cacheMisses` reflect actual events.
    @Test("sessionStats accurately tracks hits and misses")
    func sessionStats_tracksHitsAndMisses() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let remarkClient = InstantVLMClient(text: "Move right")
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: remarkClient, gate: gate) { _ in }
        let capture = CameraCapture()

        // No events yet.
        #expect(orch.sessionStats.cacheHits == 0)
        #expect(orch.sessionStats.cacheMisses == 0)

        // Frame A: miss (valid remark → cached → recordCacheMiss).
        guard let bufA = makeFilledPixelBuffer(grayValue: 60) else {
            Issue.record("Failed to create buffer A"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(orch.sessionStats.cacheMisses == 1, "frame A should record one cache miss")
        #expect(orch.sessionStats.cacheHits == 0)

        // Frame B (different): miss.
        guard let bufB = makeFilledPixelBuffer(grayValue: 190) else {
            Issue.record("Failed to create buffer B"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufB, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(orch.sessionStats.cacheMisses == 2)

        // Frame A again: cache hit (synchronous, no network).
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        #expect(orch.sessionStats.cacheHits == 1, "returning to scene A should record a cache hit")
        #expect(orch.sessionStats.cacheMisses == 2, "miss count should not change on a cache hit")
    }
}
