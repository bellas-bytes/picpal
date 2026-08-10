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
    @State private var framingMonitor: FramingMonitor?
    @State private var motionManager = MotionManager()
    @State private var tiltMonitor: TiltMonitor?
    @State private var cueEngine: CueEngine?
    @State private var accumulator: SignalFrameAccumulator?

    var body: some View {
        ZStack {
            CameraPreviewView(camera: camera)
                .ignoresSafeArea()

            GuidesOverlayView(viewModel: debugViewModel)
                .ignoresSafeArea()

            DebugOverlayView(viewModel: debugViewModel)
        }
        .onAppear(perform: wireUp)
    }

    // MARK: - Composition root

    @MainActor
    private func wireUp() {
        guard telemetryFeed == nil else { return }  // idempotent

        // Create the cue engine and signal accumulator.
        // The accumulator merges individual signals into a complete SignalFrame and
        // passes it to the engine on every update. Results are dispatched to @MainActor.
        let engine = CueEngine()
        let accum = SignalFrameAccumulator { [weak debugViewModel] frame in
            let cue = engine.process(frame: frame)
            let cueText = cue?.text ?? "—"
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.activeCue = cueText
            }
        }

        let framingMon = FramingMonitor { [weak debugViewModel, accum] signal in
            accum.update(framing: signal)
            let label = signal.hint.rawValue
            let box = signal.subjectBox
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.framingHint = label
                debugViewModel?.subjectBox = box
            }
        }

        let exposureMon = ExposureMonitor(downstream: framingMon) { [weak debugViewModel, accum] signal in
            accum.update(exposure: signal)
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

        let blurMon = BlurMonitor(downstream: exposureMon) { [weak debugViewModel, accum] signal in
            accum.update(blur: signal)
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
        framingMonitor = framingMon
        landmarkProbe = probe
        telemetryFeed = feed
        cueEngine = engine
        accumulator = accum

        let monitor = TiltMonitor { [weak debugViewModel, accum] signal in
            accum.update(tilt: signal)
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.tiltDegrees = signal.angleDegrees
                debugViewModel?.isLevel = signal.isLevel
            }
        }
        motionManager.delegate = monitor
        motionManager.start()
        tiltMonitor = monitor
    }
}
