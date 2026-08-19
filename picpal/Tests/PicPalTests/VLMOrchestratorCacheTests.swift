import Testing
import CoreVideo
import CoreMedia
import Foundation
import UIKit
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

    // MARK: - Test 1: cache hit with remark-returning client

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
        // VLM client must NOT have been called for the third frame (cache hit).
        #expect(client.callCount == 2, "cache hit on returning scene must not increment callCount")
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
        // Use a small synthetic UIImage — system images aren't guaranteed in test env.
        let refRenderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let refImage = refRenderer.image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        orch.referenceImage = refImage
        orch.referenceModeConsented = true // consent required for client calls

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
