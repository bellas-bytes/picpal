import AVFoundation
import CoreMedia
import CoreVideo
import os

// MARK: - Sendable wrapper

/// Wraps `CVPixelBuffer` (a non-Sendable Core Foundation type) for safe transfer
/// into the exposure dispatch queue. The serial `exposureQueue` ensures no concurrent
/// access.
private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

// MARK: - ExposureMonitor

/// Bridges `CameraFrameDelegate` callbacks to `ExposureProcessor`, dispatching
/// computation onto a dedicated serial queue so the camera frame queue is never blocked.
///
/// ## Pipeline position
/// ```
/// CameraCapture → … → BlurMonitor → ExposureMonitor → (end of chain)
/// ```
///
/// ## Threading
/// - Frame callbacks arrive on the camera frame queue.
/// - `ExposureProcessor.process` is dispatched asynchronously to `exposureQueue`
///   (`.userInitiated`).
/// - `onSignal` is called on `exposureQueue` after each frame is processed.
/// - Downstream forwarding happens synchronously on the camera queue before the async
///   dispatch, so downstream always receives frames without waiting for exposure
///   computation.
///
/// ## Sendable
/// `ExposureMonitor` is `@unchecked Sendable`. Its stored `processor` and `onSignal`
/// are immutable after init; the `downstream` weak reference is only ever written
/// by ARC.
public final class ExposureMonitor: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Constants

    private enum QueueConstants {
        static let label = "com.picpal.signals.exposure"
        static let qos: DispatchQoS = .userInitiated
    }

    // MARK: - Properties

    private let processor: ExposureProcessor
    private let onSignal: @Sendable (ExposureSignal) -> Void
    private weak var downstream: (any CameraFrameDelegate)?

    private let exposureQueue = DispatchQueue(
        label: QueueConstants.label,
        qos:   QueueConstants.qos
    )

    /// Prevents queue growth when processing is slower than frame delivery.
    /// Frames arriving while a prior frame is still being analysed are dropped.
    private let isProcessing = OSAllocatedUnfairLock<Bool>(initialState: false)

    // MARK: - Init

    /// Creates an `ExposureMonitor`.
    ///
    /// - Parameters:
    ///   - processor: The `ExposureProcessor` applied to each frame. Defaults to
    ///     `ExposureProcessor()`.
    ///   - downstream: Next pipeline delegate; receives every frame on the camera queue.
    ///   - onSignal: Called on `exposureQueue` with each computed `ExposureSignal`.
    ///               Dispatch to `@MainActor` inside this closure to update UI.
    public init(
        processor: ExposureProcessor = ExposureProcessor(),
        downstream: (any CameraFrameDelegate)? = nil,
        onSignal: @escaping @Sendable (ExposureSignal) -> Void
    ) {
        self.processor  = processor
        self.downstream = downstream
        self.onSignal   = onSignal
    }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // Forward synchronously so downstream is never delayed by exposure computation.
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        // Drop-if-busy: skip analysis when the previous frame hasn't finished yet.
        // This bounds queue depth to 1 and prevents unbounded CVPixelBuffer retention.
        guard isProcessing.withLock({ !$0 }) else { return }
        isProcessing.withLock { $0 = true }

        // Dispatch exposure processing off the camera queue.
        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        exposureQueue.async { [weak self] in
            defer { self?.isProcessing.withLock { $0 = false } }
            guard let self else { return }
            let signal = processor.process(pixelBuffer: wrapped.value)
            onSignal(signal)
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }
}
