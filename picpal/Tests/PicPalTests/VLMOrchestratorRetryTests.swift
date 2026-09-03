import Testing
import Foundation
import CoreMedia
import os
@testable import PicPal

// MARK: - Mock VLMClient helpers for retry tests

/// Client that fails a configurable number of times then succeeds.
final class FailThenSucceedVLMClient: VLMClient, @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let failCount: Int
    private let error: VLMError
    let successResponse: VLMResponse

    init(
        failCount: Int,
        error: VLMError = .networkFailure("simulated"),
        successText: String = "great shot"
    ) {
        self.failCount = failCount
        self.error = error
        self.successResponse = VLMResponse(text: successText)
    }

    var callCount: Int { lock.withLock { $0 } }

    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        let call = lock.withLock { state -> Int in
            state += 1
            return state
        }
        if call <= failCount { throw error }
        return successResponse
    }
}

/// Client that always throws a fixed error.
final class FixedErrorVLMClient: VLMClient, @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let error: VLMError

    init(error: VLMError) { self.error = error }

    var callCount: Int { lock.withLock { $0 } }

    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        lock.withLock { $0 += 1 }
        throw error
    }
}

// MARK: - VLMOrchestratorRetryTests

/// Tests for the `analyzeWithRetry` path inside `VLMOrchestrator`.
///
/// `@Suite(.serialized)` prevents races on `VLMSettings.shared.isOnDeviceOnly`.
@Suite("VLMOrchestrator retry-with-backoff", .serialized)
struct VLMOrchestratorRetryTests {

    private func enableCloudVLM() { VLMSettings.shared.isOnDeviceOnly = false }
    private func resetVLMSettings() {
        UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey)
    }

    // MARK: - Test 1: fails twice then succeeds

    @Test("Client returns networkFailure twice then succeeds — orchestrator delivers signal")
    func failTwiceThenSucceed_deliversSignal() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = FailThenSucceedVLMClient(failCount: 2, error: .networkFailure("down"))
        let receivedLock = OSAllocatedUnfairLock<AestheticSignal?>(initialState: nil)
        let completedLock = OSAllocatedUnfairLock<Int>(initialState: 0)
        let orch = VLMOrchestrator(
            client: client,
            retrySleep: { _ in },
            onRequestCompleted: { completedLock.withLock { $0 += 1 } }
        ) { signal in
            receivedLock.withLock { $0 = signal }
        }

        guard let buf = makeFilledPixelBuffer(grayValue: 200) else {
            Issue.record("Could not create pixel buffer"); return
        }
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buf, timestamp: CMTime(value: 1, timescale: 30))

        let deadline = Date().addingTimeInterval(5)
        while completedLock.withLock({ $0 }) == 0, Date() < deadline { await Task.yield() }

        // Three analyze calls: 2 failures + 1 success.
        #expect(client.callCount == 3)
        // A signal is delivered on success.
        #expect(receivedLock.withLock({ $0 }) != nil)
    }

    // MARK: - Test 2: 503 surfaces without retry

    @Test("HTTP 503 is NOT retried — client called exactly once")
    func http503_noRetry() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = FixedErrorVLMClient(error: .httpError(statusCode: 503, body: "ceiling hit"))
        let completedLock = OSAllocatedUnfairLock<Int>(initialState: 0)
        let orch = VLMOrchestrator(
            client: client,
            retrySleep: { _ in },
            onRequestCompleted: { completedLock.withLock { $0 += 1 } }
        ) { _ in }

        guard let buf = makeFilledPixelBuffer(grayValue: 100) else {
            Issue.record("Could not create pixel buffer"); return
        }
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buf, timestamp: CMTime(value: 1, timescale: 30))

        let deadline = Date().addingTimeInterval(3)
        while completedLock.withLock({ $0 }) == 0, Date() < deadline { await Task.yield() }

        // 503 must not be retried — exactly one call.
        #expect(client.callCount == 1)
    }

    // MARK: - Test 3: retry delay timing constants

    @Test("Retry delay constants: 1 s on first retry, 2 s on second")
    func retryDelayConstants_areCorrect() {
        let base = VLMOrchestrator.retryBaseDelayNanoseconds
        #expect(base == 1_000_000_000,  "base should be 1 second in nanoseconds")
        #expect(base * 1 == 1_000_000_000, "first retry delay should be 1 s")
        #expect(base * 2 == 2_000_000_000, "second retry delay should be 2 s")
        #expect(VLMOrchestrator.maxRetryAttempts == 2)
    }

    // MARK: - Test 4: HTTP 502 triggers retry

    @Test("HTTP 502 IS retried — client called 3 times (1 initial + 2 retries)")
    func http502_isRetried_threeCallsTotal() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = FixedErrorVLMClient(error: .httpError(statusCode: 502, body: "bad gateway"))
        let completedLock = OSAllocatedUnfairLock<Int>(initialState: 0)
        let orch = VLMOrchestrator(
            client: client,
            retrySleep: { _ in },   // instant — no real delays
            onRequestCompleted: { completedLock.withLock { $0 += 1 } }
        ) { _ in }

        guard let buf = makeFilledPixelBuffer(grayValue: 50) else {
            Issue.record("Could not create pixel buffer"); return
        }
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buf, timestamp: CMTime(value: 1, timescale: 30))

        let deadline = Date().addingTimeInterval(3)
        while completedLock.withLock({ $0 }) == 0, Date() < deadline { await Task.yield() }

        // 1 initial + 2 retries = 3 total calls.
        #expect(client.callCount == 3)
    }

    // MARK: - Test 5: injected sleep receives correct nanosecond values

    @Test("Injected sleep called with 1 s then 2 s on two successive retries")
    func retrySleep_receivesCorrectDelays() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = FixedErrorVLMClient(error: .networkFailure("down"))
        let sleepLock = OSAllocatedUnfairLock<[UInt64]>(initialState: [])
        let completedLock = OSAllocatedUnfairLock<Int>(initialState: 0)
        let orch = VLMOrchestrator(
            client: client,
            retrySleep: { ns in sleepLock.withLock { $0.append(ns) } },
            onRequestCompleted: { completedLock.withLock { $0 += 1 } }
        ) { _ in }

        guard let buf = makeFilledPixelBuffer(grayValue: 70) else {
            Issue.record("Could not create pixel buffer"); return
        }
        orch.cameraCapture(CameraCapture(), didOutputPixelBuffer: buf, timestamp: CMTime(value: 1, timescale: 30))

        let deadline = Date().addingTimeInterval(3)
        while completedLock.withLock({ $0 }) == 0, Date() < deadline { await Task.yield() }

        let delays = sleepLock.withLock { $0 }
        #expect(delays.count == 2)
        #expect(delays.first == 1_000_000_000)
        #expect(delays.last  == 2_000_000_000)
    }
}
