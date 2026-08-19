import AVFoundation
import CoreMedia
import CoreVideo

/// Receives raw frames and lifecycle events from a `CameraCapture` instance.
///
/// ## Threading
/// - `didOutputPixelBuffer` is called on the capture pipeline's dedicated **frame queue**
///   (never the main thread). Implementations must be prepared to receive calls off-main.
/// - `didChangeState` is always dispatched to the **main queue** before the call returns
///   to the capture pipeline.
public protocol CameraFrameDelegate: AnyObject {

    /// Delivers a raw video frame for downstream analysis.
    ///
    /// - Parameters:
    ///   - capture: The `CameraCapture` instance producing the frame.
    ///   - pixelBuffer: The uncompressed image data in `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` format.
    ///   - timestamp: Presentation timestamp from the sample buffer.
    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    )

    /// Reports a change in the capture session's lifecycle state.
    ///
    /// Always called on the main queue.
    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    )
}
