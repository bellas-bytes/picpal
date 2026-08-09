import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// A `CameraFrameDelegate` that sits between `CameraCapture` and a downstream delegate,
/// measuring frame-arrival timing and computing frames per second.
///
/// ## Pipeline position
/// ```
/// CameraCapture → PipelineTelemetryBridge → downstream (nil until analysis is added)
/// ```
///
/// ## Threading model
/// Frame callbacks arrive on the camera's dedicated `frameQueue`. All shared state is
/// protected by `OSAllocatedUnfairLock`. `FrameTimer.stop(token:)` is dispatched via
/// `Task` — elapsed time is computed from the token's captured start instant, so
/// scheduling delay does not inflate the measurement.
///
/// `PipelineTelemetryBridge` is `@unchecked Sendable`: all mutable state is synchronised
/// via `OSAllocatedUnfairLock`.
public final class PipelineTelemetryBridge: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Constants

    private enum Constants {
        /// Rolling window duration for FPS calculation (seconds).
        static let fpsWindowSeconds: Double = 1.0
    }

    // MARK: - Dependencies

    /// The underlying frame timer; accessible for external statistics reads.
    public let frameTimer: FrameTimer

    private let onFPSUpdate: @Sendable (Double) -> Void
    private weak var downstream: (any CameraFrameDelegate)?
    private let logger = Logger(subsystem: "com.picpal", category: "PipelineTelemetryBridge")

    // MARK: - FPS window state (lock-protected)

    private struct WindowState {
        var frameCount: Int = 0
        var windowStart: ContinuousClock.Instant = .now
    }

    private let windowLock = OSAllocatedUnfairLock<WindowState>(initialState: WindowState())

    // MARK: - Init

    public init(
        frameTimer: FrameTimer = FrameTimer(),
        downstream: (any CameraFrameDelegate)? = nil,
        onFPSUpdate: @escaping @Sendable (Double) -> Void = { _ in }
    ) {
        self.frameTimer = frameTimer
        self.downstream = downstream
        self.onFPSUpdate = onFPSUpdate
    }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        let token = frameTimer.start()
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)
        Task { await frameTimer.stop(token: token) }
        tickFPSWindow()
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }

    // MARK: - Private

    /// Increment the frame counter; emit FPS via `onFPSUpdate` when the window expires.
    private nonisolated func tickFPSWindow() {
        let fps: Double? = windowLock.withLock { state in
            state.frameCount += 1
            let elapsed = ContinuousClock.now - state.windowStart
            let (secs, attos) = elapsed.components
            let seconds = Double(secs) + Double(attos) / 1_000_000_000_000_000_000
            guard seconds >= Constants.fpsWindowSeconds else { return nil }
            let measured = Double(state.frameCount) / seconds
            state.frameCount = 0
            state.windowStart = .now
            return measured
        }
        if let fps {
            logger.debug("FPS: \(fps, format: .fixed(precision: 1), privacy: .public)")
            onFPSUpdate(fps)
        }
    }
}
