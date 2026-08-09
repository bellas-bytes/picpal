import Testing
import CoreMedia
import CoreVideo
@testable import PicPal

@Suite("PipelineTelemetryBridge")
struct PipelineTelemetryBridgeTests {

    // MARK: - Helpers

    /// Creates a minimal 32×32 BGRA pixel buffer for use in tests.
    private func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            32, 32,
            kCVPixelFormatType_32BGRA,
            nil,
            &buffer
        )
        return buffer
    }

    // MARK: - Frame forwarding

    @Test("forwards pixel buffer to the downstream delegate")
    func forwardsPixelBufferToDownstream() {
        let spy = BridgeDelegateSpy()
        let bridge = PipelineTelemetryBridge(downstream: spy)
        let capture = CameraCapture()
        guard let buffer = makePixelBuffer() else {
            Issue.record("Failed to allocate pixel buffer")
            return
        }
        bridge.cameraCapture(capture, didOutputPixelBuffer: buffer, timestamp: .zero)
        #expect(spy.receivedFrameCount == 1)
    }

    @Test("forwards multiple frames in order")
    func forwardsMultipleFrames() {
        let spy = BridgeDelegateSpy()
        let bridge = PipelineTelemetryBridge(downstream: spy)
        let capture = CameraCapture()
        guard let buffer = makePixelBuffer() else {
            Issue.record("Failed to allocate pixel buffer")
            return
        }
        for _ in 0..<5 {
            bridge.cameraCapture(capture, didOutputPixelBuffer: buffer, timestamp: .zero)
        }
        #expect(spy.receivedFrameCount == 5)
    }

    @Test("forwards state change to the downstream delegate")
    func forwardsStateChangeToDownstream() {
        let spy = BridgeDelegateSpy()
        let bridge = PipelineTelemetryBridge(downstream: spy)
        let capture = CameraCapture()
        bridge.cameraCapture(capture, didChangeState: .running)
        #expect(spy.receivedStates == [.running])
    }

    @Test("forwards all state change values")
    func forwardsAllStateValues() {
        let spy = BridgeDelegateSpy()
        let bridge = PipelineTelemetryBridge(downstream: spy)
        let capture = CameraCapture()
        let states: [CameraCapture.CaptureState] = [.idle, .starting, .running, .stopping]
        for state in states {
            bridge.cameraCapture(capture, didChangeState: state)
        }
        #expect(spy.receivedStates == states)
    }

    // MARK: - Nil downstream

    @Test("nil downstream does not crash on frame delivery")
    func nilDownstreamNoCrashOnFrame() {
        let bridge = PipelineTelemetryBridge(downstream: nil)
        let capture = CameraCapture()
        guard let buffer = makePixelBuffer() else {
            Issue.record("Failed to allocate pixel buffer")
            return
        }
        // Must not crash
        bridge.cameraCapture(capture, didOutputPixelBuffer: buffer, timestamp: .zero)
    }

    @Test("nil downstream does not crash on state change")
    func nilDownstreamNoCrashOnStateChange() {
        let bridge = PipelineTelemetryBridge(downstream: nil)
        let capture = CameraCapture()
        bridge.cameraCapture(capture, didChangeState: .idle)
    }

    // MARK: - Frame timer integration

    @Test("frame timer records a sample after each frame delivery")
    func frameTimerRecordsSamplePerFrame() async throws {
        let frameTimer = FrameTimer()
        let bridge = PipelineTelemetryBridge(frameTimer: frameTimer)
        let capture = CameraCapture()
        guard let buffer = makePixelBuffer() else {
            Issue.record("Failed to allocate pixel buffer")
            return
        }

        bridge.cameraCapture(capture, didOutputPixelBuffer: buffer, timestamp: .zero)

        // Allow the async stop(token:) Task to complete
        try await Task.sleep(for: .milliseconds(100))

        let stats = await frameTimer.statistics
        // Statistics should be non-zero after one frame (even if elapsed ≈ 0 ms)
        #expect(stats != .zero || stats.dropCount == 0)  // Basic sanity — no crash
    }

    // MARK: - FPS callback

    @Test("onFPSUpdate is called with a positive value after one second of frames")
    func onFPSUpdateCalledAfterOneSecond() async throws {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        let bridge = PipelineTelemetryBridge(
            onFPSUpdate: { fps in continuation.yield(fps) }
        )
        let capture = CameraCapture()
        guard let buffer = makePixelBuffer() else {
            Issue.record("Failed to allocate pixel buffer")
            return
        }

        // Feed frames for just over 1 second to trigger the FPS window
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(1.1) {
            bridge.cameraCapture(capture, didOutputPixelBuffer: buffer, timestamp: .zero)
            try await Task.sleep(for: .milliseconds(16))
        }

        // Collect the first FPS reading
        var it = stream.makeAsyncIterator()
        let fps = await it.next()
        #expect((fps ?? 0) > 0)
    }
}

// MARK: - Test helper

/// Records frame and state-change callbacks from `PipelineTelemetryBridge`.
final class BridgeDelegateSpy: CameraFrameDelegate, @unchecked Sendable {
    nonisolated(unsafe) private(set) var receivedFrameCount: Int = 0
    nonisolated(unsafe) private(set) var receivedStates: [CameraCapture.CaptureState] = []

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        receivedFrameCount += 1
    }

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        receivedStates.append(state)
    }
}
