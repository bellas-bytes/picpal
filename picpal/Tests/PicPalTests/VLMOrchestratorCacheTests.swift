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

    /// Reference profile/comparison requests never read a generic aesthetic cache entry,
    /// including a fresh requested verification of the identical scene.
    @Test("reference mode bypasses generic cache for profile, comparison and requested verification")
    func referenceMode_bypassesCache() async {
        enableCloudVLM()
        defer { resetVLMSettings() }
        let time = OSAllocatedUnfairLock(initialState: 100.0)
        let completions = OSAllocatedUnfairLock(initialState: 0)
        let events = OSAllocatedUnfairLock(initialState: 0)
        let genericSignals = OSAllocatedUnfairLock(initialState: 0)
        let client = CacheReferenceStructuredClient()
        let liveEncodes = OSAllocatedUnfairLock(initialState: 0)
        let referenceEncodes = OSAllocatedUnfairLock(initialState: 0)
        let cache = VLMResponseCache()
        let gate = VLMRequestGate(clock: { time.withLock { $0 } })
        let orch = VLMOrchestrator(client: client,
            encodeLive: { buffer in liveEncodes.withLock { $0 += 1 }; return FrameEncoder.encode(pixelBuffer: buffer) },
            encodeReference: { image in referenceEncodes.withLock { $0 += 1 }; return FrameEncoder.encodeUIImage(image) },
            gate: gate, responseCache: cache,
            onRequestCompleted: { completions.withLock { $0 += 1 } },
            clock: { time.withLock { $0 } },
            onReferenceAnalysis: { event in
                if case .comparison = event { events.withLock { $0 += 1 } }
            },
            onAestheticSignal: { _ in genericSignals.withLock { $0 += 1 } })
        let capture = CameraCapture()
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        let image = renderer.image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        orch.setReferenceContext(sessionID: UUID(), generation: 1, image: image, consented: true, geometryRevision: 0)
        orch.updateReferenceMotion(isSettled: true)
        guard let buffer = makeFilledPixelBuffer(grayValue: 80),
              let signature = SceneSignature.compute(from: buffer) else {
            Issue.record("Failed to create reference scene"); return
        }
        // Seed after context setup (which intentionally invalidates earlier generic cache entries).
        cache.store(AestheticSignal(remark: "Move left.", confidence: 1, hint: .remark), for: signature)
        for requestIndex in 0..<3 {
            time.withLock { $0 = 100 + Double(requestIndex) * 8 }
            if requestIndex == 1 {
                orch.updateReferenceMotion(isSettled: false)
                orch.cameraCapture(capture, didOutputPixelBuffer: buffer,
                    timestamp: CMClockGetTime(CMClockGetHostTimeClock()))
                try? await Task.sleep(nanoseconds: 40_000_000)
                #expect(client.operations == [.referenceProfile], "Moving phone must not dispatch a comparison")
                orch.updateReferenceMotion(isSettled: true)
            }
            if requestIndex == 2 { orch.requestReferenceVerification() }
            orch.cameraCapture(capture, didOutputPixelBuffer: buffer,
                timestamp: CMClockGetTime(CMClockGetHostTimeClock()))
            for _ in 0..<100 where completions.withLock({ $0 }) < requestIndex + 1 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(completions.withLock { $0 } == requestIndex + 1)
        }
        #expect(client.operations == [.referenceProfile, .referenceComparison, .referenceComparison])
        #expect(liveEncodes.withLock { $0 } == 2, "Profile must never encode a live frame")
        #expect(referenceEncodes.withLock { $0 } == 1, "Comparisons must reuse the consented reference JPEG")
        #expect(events.withLock { $0 } == 2)
        #expect(genericSignals.withLock { $0 } == 0)
        #expect(orch.sessionStats.cacheHits == 0)
        #expect(orch.sessionStats.cacheMisses == 0)
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

private final class CacheReferenceStructuredClient: VLMClient, @unchecked Sendable {
    private let recorded = OSAllocatedUnfairLock<[VLMOperation]>(initialState: [])
    var operations: [VLMOperation] { recorded.withLock { $0 } }
    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        recorded.withLock { $0.append(request.operation) }
        let data: Data
        if request.operation == .referenceProfile {
            let profile = ReferenceProfile(schemaVersion: 1, summary: "Portrait", features: ReferenceDimension.allCases.map {
                ReferenceFeature(dimension: $0, evidence: "Visible", confidence: 0.9, applicable: true)
            })
            data = try! JSONEncoder().encode(profile)
        } else {
            let comparison = ReferenceComparison(schemaVersion: 1, dimensions: ReferenceDimension.allCases.map {
                ReferenceDimensionComparison(dimension: $0, status: .matched,
                    referenceEvidence: "Visible", liveEvidence: "Visible", confidence: 0.9)
            }, action: nil)
            data = try! JSONEncoder().encode(comparison)
        }
        return VLMResponse(text: String(decoding: data, as: UTF8.self))
    }
}


extension VLMOrchestratorCacheTests {
    @Test(arguments: [0, 2])
    func cacheDeliveryNeverConsumesNetworkBudget(capacity: Int) async {
        enableCloudVLM()
        defer { resetVLMSettings() }
        let budget = VLMSessionBudget(maxCalls: capacity)
        let client = CountingVLMClient()
        let cache = VLMResponseCache()
        let signals = OSAllocatedUnfairLock(initialState: 0)
        let orch = VLMOrchestrator(client: client,
            gate: VLMRequestGate(cadenceSeconds: 0, budget: budget), responseCache: cache) { _ in
            signals.withLock { $0 += 1 }
        }
        let buffer = makeFilledPixelBuffer(grayValue: 80)!
        cache.store(AestheticSignal(remark: "Move left.", confidence: 1, hint: .remark),
                    for: SceneSignature.compute(from: buffer)!)
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buffer, timestamp: .zero)
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buffer, timestamp: .zero)
        #expect(signals.withLock { $0 } == 1)
        #expect(client.callCount == 0)
        #expect(budget.callsRemaining == capacity)
        #expect(orch.sessionStats.cacheHits == 1)
    }
}

struct VLMCompletionTelemetryTests {
    @Test func completionSamplesAreBoundedAndResetClearsCounters() {
        var stats = VLMSessionStats()
        for index in 0..<140 {
            let id = UUID()
            stats.begin(id: id, operation: .aesthetic, capturedAt: 100, encodingSeconds: 0.25, cacheHit: false)
            stats.dispatched(id: id, at: 101)
            stats.completed(id: id, at: 104 + Double(index), outcome: .accepted)
        }
        #expect(stats.networkAttempts == 140)
        #expect(stats.acceptedResults == 140)
        #expect(stats.requests.count == 128)
        #expect(stats.requests.first?.completionLatency == 16)
        stats = VLMSessionStats()
        #expect(stats.networkAttempts == 0)
        #expect(stats.requests.isEmpty)
    }
}

extension VLMOrchestratorCacheTests {
    @Test(arguments: [false, true])
    func failedEncodingOrContextChangeBeforeDispatchSpendsNothing(changeContext: Bool) async {
        enableCloudVLM()
        defer { resetVLMSettings() }
        let budget = VLMSessionBudget(maxCalls: 2)
        let client = CountingVLMClient()
        let encoded = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let orch = VLMOrchestrator(client: client, encodeLive: { _ in
            encoded.withLock { $0 = true }
            release.wait()
            return changeContext ? Data([1]) : nil
        }, gate: VLMRequestGate(budget: budget)) { _ in }
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: makeFilledPixelBuffer(grayValue: 80)!, timestamp: .zero)
        for _ in 0..<100 where !encoded.withLock({ $0 }) { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(encoded.withLock { $0 })
        if changeContext {
            orch.setReferenceContext(sessionID: UUID(), generation: 1, image: nil, consented: false, geometryRevision: 0)
        }
        release.signal()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(client.callCount == 0)
        #expect(budget.callsRemaining == 2)
        #expect(orch.sessionStats.networkAttempts == 0)
    }
}
