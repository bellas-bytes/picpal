import SwiftUI
import AVFoundation
import Combine

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
    /// Committed camera position; input-port geometry remains authoritative for mirroring.
    var cameraPosition: AVCaptureDevice.Position
    var orientation: CaptureOrientation = .portrait
    var coordinateConverter: CameraPreviewCoordinates? = nil
    var onInterfaceOrientationChange: ((UIInterfaceOrientation) -> Void)? = nil

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
        context.coordinator.attach(container: container, to: camera.captureSession)
        coordinateConverter?.layer = container.previewLayer
        coordinateConverter?.container = container
        return container
    }

    func updateUIView(_ uiView: CameraContainerView, context: Context) {
        uiView.requestedOrientation = orientation
        uiView.onInterfaceOrientationChange = onInterfaceOrientationChange
        uiView.refreshConnection()
    }
}

@MainActor
final class CameraPreviewCoordinates {
    weak var layer: AVCaptureVideoPreviewLayer?
    weak var container: CameraContainerView?

    func beginSwitch() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.isHidden = true
        CATransaction.commit()
    }

    func endSwitch() {
        container?.refreshConnection()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.isHidden = false
        CATransaction.commit()
    }

    func devicePoint(at point: CGPoint) -> CGPoint? {
        layer?.captureDevicePointConverted(fromLayerPoint: point)
    }

    func devicePoint(forVisionPoint point: CGPoint) -> CGPoint? {
        guard let layer else { return nil }
        return layer.captureDevicePointConverted(fromLayerPoint:
            CGPoint(x: point.x * layer.bounds.width, y: (1 - point.y) * layer.bounds.height))
    }
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

        private var sessionObservation: AnyCancellable?

        /// Connect `previewLayer` to `session`. No delegate assignment — the composition
        /// root wires the delegate after `makeUIView` returns.
        func attach(container: CameraContainerView, to session: AVCaptureSession) {
            container.previewLayer.session = session
            // Session setup and camera switching create connections asynchronously,
            // often after SwiftUI's last updateUIView call.
            sessionObservation = NotificationCenter.default.publisher(for: AVCaptureSession.didStartRunningNotification, object: session)
                .merge(with: NotificationCenter.default.publisher(for: CameraCapture.connectionsChangedNotification, object: session))
                // Notifications arrive synchronously on the camera's session queue.
                // Do not inherit this method's MainActor isolation at sink entry.
                .sink { @Sendable [weak container] _ in
                    Task { @MainActor in container?.refreshConnection() }
                }
        }
    }
}

// MARK: - Container view

/// A `UIView` whose backing `CALayer` is `AVCaptureVideoPreviewLayer`.
final class CameraContainerView: UIView {

    var requestedOrientation: CaptureOrientation = .portrait
    var onInterfaceOrientationChange: ((UIInterfaceOrientation) -> Void)?
    private var reportedOrientation: UIInterfaceOrientation?

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshConnection()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshConnection()
    }

    func refreshConnection() {
        let sceneOrientation = window?.windowScene?.interfaceOrientation
        let actual = sceneOrientation.map { requestedOrientation.updated(forInterface: $0) } ?? requestedOrientation
        if let connection = previewLayer.connection {
            // The connected input is authoritative: SwiftUI can still carry the
            // previous position while AVFoundation installs the new connection.
            let mirrored = connection.inputPorts.first(where: { $0.mediaType == .video })?
                .sourceDevicePosition == .front
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if connection.isVideoOrientationSupported, connection.videoOrientation != actual.videoOrientation {
                connection.videoOrientation = actual.videoOrientation
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirrored != mirrored { connection.isVideoMirrored = mirrored }
            }
            CATransaction.commit()
        }
        // Device orientation notifications may arrive before UIKit finishes rotating.
        // Report the actual hosting scene's orientation after its layout changes.
        if let sceneOrientation, sceneOrientation != .unknown,
           sceneOrientation != reportedOrientation, let callback = onInterfaceOrientationChange {
            reportedOrientation = sceneOrientation
            Task { @MainActor in callback(sceneOrientation) }
        }
    }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: layerClass guarantees the layer is always this type.
        layer as! AVCaptureVideoPreviewLayer  // swiftlint:disable:this force_cast
    }
}

/// Requests a coherent UIKit rotation; capture and preview still follow the
/// resulting scene orientation, including when UIKit rejects the request.
@MainActor
final class CameraSceneRotationCoordinator {
    private var attemptedOrientation: CaptureOrientation?

    func update(physicalOrientation: CaptureOrientation, interfaceOrientation: UIInterfaceOrientation,
                isActive: Bool, hasPresentedController: Bool,
                request: (UIInterfaceOrientationMask) -> Void) {
        guard isActive, !hasPresentedController else { return }
        let desired: UIInterfaceOrientationMask = switch physicalOrientation {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        }
        let current = CaptureOrientation.portrait.updated(forInterface: interfaceOrientation)
        guard interfaceOrientation != .unknown, current != physicalOrientation else {
            attemptedOrientation = nil
            return
        }
        guard attemptedOrientation != physicalOrientation else { return }
        attemptedOrientation = physicalOrientation
        request(desired)
    }
}
