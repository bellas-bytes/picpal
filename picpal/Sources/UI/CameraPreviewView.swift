import SwiftUI
import AVFoundation
import CoreMedia
import CoreVideo

/// A full-screen `UIViewRepresentable` that renders the live camera feed from
/// a `CameraCapture` session via `AVCaptureVideoPreviewLayer`.
///
/// The preview layer's session is connected after `CameraCapture` transitions to
/// `.running`, because `CameraCapture.buildSession()` constructs a new
/// `AVCaptureSession` asynchronously on first start.
struct CameraPreviewView: UIViewRepresentable {

    let camera: CameraCapture

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    func makeUIView(context: Context) -> CameraContainerView {
        let container = CameraContainerView()
        container.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(camera: camera, previewLayer: container.previewLayer)
        camera.requestPermissionAndStart()
        return container
    }

    func updateUIView(_ uiView: CameraContainerView, context: Context) {}
}

// MARK: - Coordinator

extension CameraPreviewView {

    /// Bridges `CameraFrameDelegate` state callbacks into preview-layer session updates.
    ///
    /// The coordinator is owned by SwiftUI's rendering context for the lifetime of the
    /// view and is stored as a weak delegate by `CameraCapture`.
    @MainActor
    final class Coordinator: CameraFrameDelegate {

        private weak var previewLayer: AVCaptureVideoPreviewLayer?

        /// Wire up the camera delegate and store the preview layer reference.
        func attach(camera: CameraCapture, previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            camera.delegate = self
        }

        // Frame delivery — not needed for display scaffolding.
        nonisolated func cameraCapture(
            _ capture: CameraCapture,
            didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
            timestamp: CMTime
        ) {}

        // Connect the preview layer to the newly-built session on `.running`.
        // `didChangeState` is always dispatched to the main queue by `CameraCapture`.
        nonisolated func cameraCapture(
            _ capture: CameraCapture,
            didChangeState state: CameraCapture.CaptureState
        ) {
            guard case .running = state else { return }
            MainActor.assumeIsolated {
                previewLayer?.session = capture.captureSession
            }
        }
    }
}

// MARK: - Container view

/// A `UIView` whose backing `CALayer` is `AVCaptureVideoPreviewLayer`.
final class CameraContainerView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: layerClass guarantees the layer is always this type.
        layer as! AVCaptureVideoPreviewLayer  // swiftlint:disable:this force_cast
    }
}
