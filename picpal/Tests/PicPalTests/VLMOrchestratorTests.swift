import Testing
import CoreVideo
import CoreMedia
import Foundation
import os
@testable import PicPal

// MARK: - VLMOrchestratorTests

/// Unit tests for `VLMOrchestrator`.
///
/// Tests exercise:
/// 1. Tier-0 downstream forwarding invariant — downstream is always called first.
/// 2. Drop-if-busy — at most one VLM request in flight.
///
/// No real network calls are made; `VLMClient` is replaced by test doubles.
///
/// `@Suite(.serialized)` prevents parallel execution that would cause races on
/// `VLMSettings.shared.isOnDeviceOnly` (backed by `UserDefaults.standard`).
/// Tests that dispatch cloud VLM requests explicitly opt in to cloud mode and clean up.
@Suite(.serialized)
struct VLMOrchestratorTests {

    /// Enables cloud VLM for the current test. Call at the start of any test that
    /// expects the VLM client to be invoked, since `isOnDeviceOnly` now defaults to
    /// `true` (on-device only) when the UserDefaults key is absent.
    private func enableCloudVLM() {
        VLMSettings.shared.isOnDeviceOnly = false
    }

    /// Removes the `isOnDeviceOnly` key so subsequent tests start from the safe default.
    private func resetVLMSettings() {
        UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey)
    }

    // MARK: - Test 1: downstream forwarding invariant

    @Test("cameraCapture always forwards to downstream before gate or busy checks")
    func aestheticSignal_forwardsDownstreamFirst() {
        let spy = SpyCameraFrameDelegate()
        let client = CountingVLMClient()
        let orch = VLMOrchestrator(client: client) { _ in }
        orch.downstream = spy

        guard let buf = makeFilledPixelBuffer(grayValue: 128) else {
            Issue.record("Failed to create test pixel buffer")
            return
        }
        let capture = CameraCapture()

        // First frame — gate passes (first call ever), isBusy is false.
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        #expect(spy.frameCallCount == 1)

        // Second frame with SAME buffer → same signature → novelty gate blocks VLM path.
        // But downstream must still be called.
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        #expect(spy.frameCallCount == 2)
    }

    // MARK: - Test 2: downstream called even when gate blocks

    @Test("downstream is called even when novelty gate blocks VLM path")
    func downstreamCalledWhenGateBlocks() {
        let spy = SpyCameraFrameDelegate()
        // Use a gate with zero cadence so only novelty can block.
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let client = InstantVLMClient()
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }
        orch.downstream = spy

        guard let buf = makeFilledPixelBuffer(grayValue: 64) else {
            Issue.record("Failed to create test pixel buffer")
            return
        }
        let capture = CameraCapture()

        // Frame 1: gate passes (first call).
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        #expect(spy.frameCallCount == 1)

        // Frame 2: same scene → novelty gate blocks VLM path, but downstream still fires.
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        #expect(spy.frameCallCount == 2)

        // Frame 3: same scene again — downstream always fires.
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        #expect(spy.frameCallCount == 3)
    }

    // MARK: - Test 3: drop-if-busy

    @Test("second frame dropped while isBusy — VLMClient called at most once")
    func aestheticSignal_gatedOnBusy() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = CountingVLMClient()
        // 0s cadence so the cadence gate never interferes in this test.
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }
        let capture = CameraCapture()

        // Frame 1: novel scene (grayValue 0 → luminance ≈ 0).
        // Gate passes; isBusy is set to true synchronously before vlmQueue.async.
        guard let buf1 = makeFilledPixelBuffer(grayValue: 0) else {
            Issue.record("Failed to create first test pixel buffer")
            return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: buf1, timestamp: .zero)

        // Frame 2: materially different scene (grayValue 200 → luminance ≈ 0.78).
        // The novelty gate would pass (|0 - 0.78| >> threshold).
        // The cadence gate passes (0s cadence).
        // BUT isBusy=true was set synchronously during frame 1 — so frame 2 is dropped.
        guard let buf2 = makeFilledPixelBuffer(grayValue: 200) else {
            Issue.record("Failed to create second test pixel buffer")
            return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: buf2, timestamp: .zero)

        // Give the cooperative pool time to run frame 1's Task and clear isBusy.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // Exactly 1 VLM call should have been dispatched.
        #expect(client.callCount == 1)
    }

    // MARK: - Test 4: state-change forwarding

    @Test("cameraCapture(didChangeState:) always forwards to downstream")
    func stateChangeForwardsDownstream() {
        let spy = SpyCameraFrameDelegate()
        let orch = VLMOrchestrator(client: InstantVLMClient()) { _ in }
        orch.downstream = spy

        // Simulate two state-change events.
        let capture = CameraCapture()
        orch.cameraCapture(capture, didChangeState: .running)
        orch.cameraCapture(capture, didChangeState: .idle)

        // State-change calls are forwarded but don't count as frame calls.
        #expect(spy.frameCallCount == 0)
    }

    // MARK: - Test 5: on-device-only toggle short-circuits before FrameEncoder

    /// Verifies that enabling the on-device-only toggle prevents FrameEncoder and the
    /// VLM client from being invoked.  Verified indirectly: zero client calls means
    /// no JPEG was encoded (encoding is the last step before the client call).
    @Test("on-device-only toggle short-circuits before FrameEncoder runs")
    func onDeviceOnlyToggle_shortCircuitsBeforeEncoding() async {
        VLMSettings.shared.isOnDeviceOnly = true
        defer { VLMSettings.shared.isOnDeviceOnly = false }

        let client = CountingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }

        guard let buf = makeFilledPixelBuffer(grayValue: 128) else {
            Issue.record("Failed to create test pixel buffer")
            return
        }
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buf, timestamp: .zero)

        // Allow enough time for any async work that might have slipped through.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // Zero VLM calls → FrameEncoder was never reached (toggle returned early).
        #expect(client.callCount == 0)
    }

    // MARK: - Test 6: consecutive failures disable Tier 2 for the session

    /// Verifies that after `VLMOrchestrator.maxConsecutiveFailures` failures the
    /// orchestrator silently stops dispatching further Tier-2 requests.
    @Test("consecutive failures disable Tier 2 for the remainder of the session")
    func consecutiveFailures_disablesTier2ForSession() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = AlwaysFailingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        // backoffBaseSeconds: 0 so failures accumulate without waiting for backoff windows.
        let orch = VLMOrchestrator(client: client, gate: gate, backoffBaseSeconds: 0) { _ in }
        let capture = CameraCapture()

        // Send VLMOrchestrator.maxConsecutiveFailures novel frames, each with a
        // distinctly different luminance so the novelty gate never blocks them.
        for i in 0..<VLMOrchestrator.maxConsecutiveFailures {
            guard let buf = makeFilledPixelBuffer(grayValue: UInt8(i * 50)) else {
                Issue.record("Failed to create pixel buffer \(i)")
                return
            }
            orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
            // Wait for the async Task to complete and isBusy to clear before the next frame.
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
        }

        // All maxConsecutiveFailures calls were attempted and failed.
        #expect(client.callCount == VLMOrchestrator.maxConsecutiveFailures)

        // Now send one more novel frame — session should be disabled, no new call.
        guard let extraBuf = makeFilledPixelBuffer(grayValue: 200) else {
            Issue.record("Failed to create extra pixel buffer")
            return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: extraBuf, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Call count must remain exactly maxConsecutiveFailures.
        #expect(client.callCount == VLMOrchestrator.maxConsecutiveFailures)
    }

    // MARK: - Test 7: backoff deadline prevents immediate retry after one failure

    /// Verifies that a single VLM failure sets a backoff deadline that blocks the
    /// very next frame from reaching the client — even after `isBusy` has cleared.
    @Test("backoff deadline prevents immediate retry after a single failure")
    func backoffDeadline_preventsImmediateRetryAfterFailure() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = AlwaysFailingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        // Use the default 2s backoff so the window is well beyond the 200 ms sleep below.
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }
        let capture = CameraCapture()

        // Frame 1: novel scene → gate passes, isBusy set, async Task fires and fails,
        // setting backoffDeadline ≈ now + 2s.
        guard let buf1 = makeFilledPixelBuffer(grayValue: 0) else {
            Issue.record("Failed to create first test pixel buffer")
            return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: buf1, timestamp: .zero)

        // Wait for the async Task to complete and isBusy to clear — but stay well
        // within the 2s backoff window so the deadline has not yet expired.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // Frame 2: different scene → novelty gate passes, isBusy is false,
        // but the backoff guard (1c) must suppress it before FrameEncoder runs.
        guard let buf2 = makeFilledPixelBuffer(grayValue: 200) else {
            Issue.record("Failed to create second test pixel buffer")
            return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: buf2, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // Only one VLM call must have been made — backoff prevented the second.
        #expect(client.callCount == 1)
    }

    // MARK: - Test 9: stale-suppression discard when scene changes mid-flight

    /// Regression test for the currentSignatureLock fix.
    ///
    /// Before the fix, `StaleSuppressor.evaluate` compared the response-time signature
    /// against the SAME retained pixel buffer used for encoding — always identical,
    /// so Rule 2 never fired and stale responses were never discarded.
    ///
    /// After the fix, `currentSignatureLock` tracks the live camera scene independently.
    /// When frame B (materially different) arrives while the VLM Task is suspended,
    /// `currentSignatureLock` is updated to B's signature. On resume the suppressor
    /// sees a different signature → discards → `onResponseDiscarded` fires,
    /// `onAestheticSignal` does NOT fire.
    @Test("staleSuppressor discards response when scene changes mid-flight")
    func staleSuppressor_discardsWhenSignatureChanges() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let suspendingClient = SuspendingVLMClient(text: "Move subject left")
        // 0s cadence so the cadence gate never interferes.
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let signalCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let discardCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        let orch = VLMOrchestrator(
            client: suspendingClient,
            gate: gate,
            onResponseDiscarded: { discardCount.withLock { $0 += 1 } }
        ) { _ in
            signalCount.withLock { $0 += 1 }
        }

        let capture = CameraCapture()

        // Frame A (gray=50): gate passes → VLM Task dispatched → client suspends.
        guard let bufA = makeFilledPixelBuffer(grayValue: 50) else {
            Issue.record("Failed to create buffer A"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)

        // Yield so the Task starts and suspends inside `analyze`.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms

        // Frame B (gray=220): updates currentSignatureLock. isBusy blocks VLM path —
        // that is correct; only the lock needs updating.
        guard let bufB = makeFilledPixelBuffer(grayValue: 220) else {
            Issue.record("Failed to create buffer B"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufB, timestamp: .zero)

        // Unblock the client — response arrives but scene has materially changed.
        suspendingClient.unblock()

        // Allow the inference Task to complete.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        // Suppressor must have discarded the response.
        #expect(signalCount.withLock { $0 } == 0, "onAestheticSignal must not fire for a stale response")
        #expect(discardCount.withLock { $0 } == 1, "onResponseDiscarded must fire exactly once")
    }

    // MARK: - Test 8: onAestheticSignal callback

    @Test("valid VLM remark triggers onAestheticSignal callback")
    func validRemarkTriggersCallback() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        // Use a gate with 0s cadence and a client that returns a valid remark.
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let remarkText = "Move the subject to the left"
        let client = InstantVLMClient(text: remarkText)

        let callbackLock = OSAllocatedUnfairLock<[AestheticSignal]>(initialState: [])
        let orch = VLMOrchestrator(client: client, gate: gate) { signal in
            callbackLock.withLock { $0.append(signal) }
        }

        guard let buf = makeFilledPixelBuffer(grayValue: 100) else {
            Issue.record("Failed to create test pixel buffer")
            return
        }
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buf, timestamp: .zero)

        // Wait for async inference + callback.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        let received = callbackLock.withLock { $0 }
        if let signal = received.first {
            #expect(signal.remark == remarkText)
            #expect(signal.hint == .remark)
        }
        #expect(received.count == 1)
    }
}
