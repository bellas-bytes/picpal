import AVFoundation
import CoreMedia

// Internal helpers extracted from CameraCapture.swift.
// Kept in a separate file to stay within the 300-line file limit.

// MARK: - Thread-safe delegate wrapper

/// Thread-safe wrapper for the weak delegate reference.
///
/// `OSAllocatedUnfairLock` stores value types; a class wrapper lets us hold a weak ref inside it.
final class DelegateBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: (any CameraFrameDelegate)?

    func get() -> (any CameraFrameDelegate)? {
        lock.withLock { value }
    }

    func set(_ delegate: (any CameraFrameDelegate)?) {
        lock.withLock { value = delegate }
    }
}

// MARK: - Sample buffer bridge

/// Bridges `AVCaptureVideoDataOutputSampleBufferDelegate` to a Swift closure.
///
/// Using a separate object avoids burdening `CameraCapture` with Obj-C protocol conformance
/// and keeps the closure capture chain explicit and `@Sendable`.
final class SampleBufferReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onFrame: @Sendable (CVPixelBuffer, CMTime) -> Void

    init(onFrame: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame(pixelBuffer, timestamp)
    }
}
