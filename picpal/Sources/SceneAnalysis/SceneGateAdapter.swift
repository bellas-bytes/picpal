import AVFoundation
import CoreMedia
import CoreVideo

/// Forwards camera frames only when the SceneGate approves.
///
/// Sits between `CameraCapture` and the downstream `CameraFrameDelegate`, dropping
/// frames whose scene signature hasn't materially changed or when the device is unsettled.
final class SceneGateAdapter: @unchecked Sendable, CameraFrameDelegate {

    private let gate: SceneGate
    private let downstream: any CameraFrameDelegate

    init(gate: SceneGate, downstream: any CameraFrameDelegate) {
        self.gate = gate
        self.downstream = downstream
    }

    // MARK: - CameraFrameDelegate

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        guard gate.shouldProcess(pixelBuffer: pixelBuffer) else { return }
        downstream.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)
    }

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream.cameraCapture(capture, didChangeState: state)
    }
}
