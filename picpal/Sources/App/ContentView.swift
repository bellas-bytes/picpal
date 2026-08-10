import SwiftUI

/// Root view — full-screen camera preview with a toggleable debug overlay.
///
/// Owns the camera, telemetry feed, and landmark probe for the lifetime of the scene.
/// The landmark probe is wired as the downstream delegate in `TelemetryFeed` so every
/// settled camera frame flows through Vision body-pose, hand-pose, and face-mesh requests.
struct ContentView: View {

    @State private var camera = CameraCapture()
    @StateObject private var debugViewModel = DebugOverlayViewModel()

    // Retained for the lifetime of the view.
    @State private var telemetryFeed: TelemetryFeed?
    @State private var landmarkProbe: VisionLandmarkProbe?
    @State private var blurMonitor: BlurMonitor?
    @State private var exposureMonitor: ExposureMonitor?
    @State private var motionManager = MotionManager()
    @State private var tiltMonitor: TiltMonitor?

    var body: some View {
        ZStack {
            CameraPreviewView(camera: camera)
                .ignoresSafeArea()

            DebugOverlayView(viewModel: debugViewModel)
        }
        .onAppear(perform: wireUp)
    }

    // MARK: - Composition root

    @MainActor
    private func wireUp() {
        guard telemetryFeed == nil else { return }  // idempotent

        let exposureMon = ExposureMonitor { [weak debugViewModel] signal in
            let label: String
            switch signal.level {
            case .ok:           label = "ok"
            case .underexposed: label = "under"
            case .overexposed:  label = "over"
            }
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.exposureLevel = label
            }
        }

        let blurMon = BlurMonitor(downstream: exposureMon) { [weak debugViewModel] signal in
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.blurScore = signal.sharpnessScore
            }
        }

        let probe = VisionLandmarkProbe(isEnabled: true, downstream: blurMon) { [weak debugViewModel] stats in
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.bodyPoseMs         = stats.bodyPoseMs
                debugViewModel?.handPoseMs         = stats.handPoseMs
                debugViewModel?.faceMeshMs         = stats.faceMeshMs
                debugViewModel?.landmarkCombinedMs = stats.combinedMs
            }
        }

        let feed = debugViewModel.makeTelemetryFeed(downstream: probe)
        camera.delegate = feed.bridge
        feed.start()
        camera.requestPermissionAndStart()

        blurMonitor = blurMon
        exposureMonitor = exposureMon
        landmarkProbe = probe
        telemetryFeed = feed

        let monitor = TiltMonitor { [weak debugViewModel] signal in
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.tiltDegrees = signal.angleDegrees
            }
        }
        motionManager.delegate = monitor
        motionManager.start()
        tiltMonitor = monitor
    }
}
