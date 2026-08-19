import SwiftUI
import AVFoundation

/// A full-screen `UIViewRepresentable` that renders the live camera feed from
/// a `CameraCapture` session via `AVCaptureVideoPreviewLayer`.
///
/// The preview layer's session is connected synchronously in `makeUIView` via
/// `camera.captureSession`, which is a stable reference — `CameraCapture.buildSession()`
/// reconfigures the existing session in-place rather than replacing it.
///
/// Startup (`requestPermissionAndStart`) and delegate ownership are the
/// composition root's responsibility (`ContentView.wireUp`).
struct CameraPreviewView: UIViewRepresentable {

    let camera: CameraCapture

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    func makeUIView(context: Context) -> CameraContainerView {
        let container = CameraContainerView()
        container.previewLayer.videoGravity = .resizeAspectFill
        // Connect the preview layer to the session.  The session reference is stable
        // (buildSession reconfigures it in-place), so this single assignment suffices.
        // requestPermissionAndStart() is intentionally NOT called here — ContentView.wireUp owns startup.
        context.coordinator.attach(previewLayer: container.previewLayer, to: camera.captureSession)
        return container
    }

    func updateUIView(_ uiView: CameraContainerView, context: Context) {}
}

// MARK: - Coordinator

extension CameraPreviewView {

    /// Owns the `AVCaptureVideoPreviewLayer` for the lifetime of the SwiftUI view.
    ///
    /// The coordinator does NOT set itself as `CameraCapture.delegate` — the
    /// composition root (`ContentView.wireUp`) owns the delegate slot so the full
    /// analysis pipeline can be wired before the session starts.
    @MainActor
    final class Coordinator {

        private weak var previewLayer: AVCaptureVideoPreviewLayer?

        /// Connect `previewLayer` to `session`. No delegate assignment — the composition
        /// root wires the delegate after `makeUIView` returns.
        func attach(previewLayer: AVCaptureVideoPreviewLayer, to session: AVCaptureSession) {
            self.previewLayer = previewLayer
            previewLayer.session = session
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
