import AVFoundation
import CoreMedia
import CoreVideo
import Vision

// MARK: - Sendable wrapper

/// Wraps `CVPixelBuffer` (a non-Sendable Core Foundation type) for safe transfer
/// into the framing dispatch queue. The serial `framingQueue` ensures no concurrent
/// access to the underlying buffer.
private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

// MARK: - FramingMonitor

/// Bridges `CameraFrameDelegate` → Vision attention saliency → `FramingProcessor` → callback.
///
/// ## Pipeline position
/// ```
/// CameraCapture → … → ExposureMonitor → FramingMonitor → (end of chain)
/// ```
///
/// ## Threading
/// - Frame callbacks arrive on the camera frame queue.
/// - Vision and `FramingProcessor.process` are dispatched asynchronously to `framingQueue`
///   (`.userInitiated`) so the camera queue is never blocked.
/// - `onSignal` is called on `framingQueue` after each frame is processed.
/// - Downstream forwarding happens synchronously on the camera queue before the async
///   dispatch, so downstream always receives frames without waiting for framing computation.
///
/// ## Sendable
/// `FramingMonitor` is `@unchecked Sendable`. Stored `processor` and `onSignal` are
/// immutable after init; the `downstream` weak reference is only ever written by ARC.
public final class FramingMonitor: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Constants

    private enum QueueConstants {
        static let label = "com.picpal.signals.framing"
        static let qos: DispatchQoS = .userInitiated
    }

    // MARK: - Properties

    private let processor: FramingProcessor
    private let onSignal: @Sendable (FramingSignal) -> Void
    // `weak var` is safe without an explicit lock: ARC guarantees atomic zeroing of weak
    // references. Consistent with the same pattern in BlurMonitor and ExposureMonitor.
    private weak var downstream: (any CameraFrameDelegate)?

    private let framingQueue = DispatchQueue(
        label: QueueConstants.label,
        qos:   QueueConstants.qos
    )

    // MARK: - Init

    /// Creates a `FramingMonitor`.
    ///
    /// - Parameters:
    ///   - processor: The `FramingProcessor` applied to each frame. Defaults to
    ///     `FramingProcessor()`.
    ///   - downstream: Next pipeline delegate; receives every frame on the camera queue.
    ///   - onSignal: Called on `framingQueue` with each computed `FramingSignal`.
    ///               Dispatch to `@MainActor` inside this closure to update UI.
    public init(
        processor: FramingProcessor = FramingProcessor(),
        downstream: (any CameraFrameDelegate)? = nil,
        onSignal: @escaping @Sendable (FramingSignal) -> Void
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
        // Forward synchronously so downstream is never delayed by framing computation.
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        framingQueue.async { [weak self] in
            guard let self else { return }
            let box    = Self.extractSalientBox(from: wrapped.value)
            let signal = processor.process(subjectBox: box)
            onSignal(signal)
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }

    // MARK: - Vision

    /// Runs an attention-based saliency request and returns the primary subject's
    /// bounding box in Vision normalized coordinates (origin bottom-left, 0–1).
    ///
    /// Returns `nil` if Vision finds no salient object or the request fails.
    private static func extractSalientBox(from pixelBuffer: CVPixelBuffer) -> CGRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
        guard let observation = request.results?.first as? VNSaliencyImageObservation else {
            return nil
        }
        return observation.salientObjects?.first?.boundingBox
    }
}
