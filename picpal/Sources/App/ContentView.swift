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
    @State private var sceneGate = SceneGate()
    @State private var sceneGateAdapter: SceneGateAdapter?
    @State private var cueEngine: CueEngine?
    @State private var accumulator: SignalFrameAccumulator?
    @State private var voiceCoach = VoiceCoach()

    var body: some View {
        ZStack {
            CameraPreviewView(camera: camera)
                .ignoresSafeArea()

            GuidesOverlayView(viewModel: debugViewModel)
                .ignoresSafeArea()

            DebugOverlayView(viewModel: debugViewModel)
        }
        .onAppear(perform: wireUp)
        .onChange(of: debugViewModel.isMuted) { _, muted in
            voiceCoach.isMuted = muted
        }
    }

    // MARK: - Composition root

    @MainActor
    private func wireUp() {
        guard telemetryFeed == nil else { return }  // idempotent

        // Create the cue engine and signal accumulator.
        // The accumulator merges individual signals into a complete SignalFrame and
        // passes it to the engine on every update. Results are dispatched to @MainActor.
        let engine = CueEngine()
        let coach = voiceCoach  // capture strong local reference (no retain cycle)
        let accum = SignalFrameAccumulator { [weak debugViewModel] frame in
            let cue = engine.process(frame: frame)
            if let cue {
                coach.speak(cue)
            }
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

        // Landmark probe is disabled by default — body/hand/face Vision runs every frame
        // and wastes thermal budget when nothing yet consumes landmark results (M2+).
        let probe = VisionLandmarkProbe(isEnabled: false, downstream: blurMon) { [weak debugViewModel] stats in
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.bodyPoseMs         = stats.bodyPoseMs
                debugViewModel?.handPoseMs         = stats.handPoseMs
                debugViewModel?.faceMeshMs         = stats.faceMeshMs
                debugViewModel?.landmarkCombinedMs = stats.combinedMs
            }
        }

        let feed = debugViewModel.makeTelemetryFeed(downstream: probe)
        let adapter = SceneGateAdapter(gate: sceneGate, downstream: feed.bridge)
        camera.delegate = adapter
        feed.start()
        camera.requestPermissionAndStart()

        blurMonitor = blurMon
        exposureMonitor = exposureMon
        framingMonitor = framingMon
        landmarkProbe = probe
        telemetryFeed = feed
        sceneGateAdapter = adapter
        cueEngine = engine
        accumulator = accum

        let monitor = TiltMonitor(onSettleChange: { [sceneGate] settled in
            sceneGate.update(isSettled: settled)
        }) { [weak debugViewModel, accum] signal in
            accum.update(tilt: signal)
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.tiltDegrees = signal.angleDegrees
                debugViewModel?.isLevel = signal.isLevel
            }
        }
        motionManager.delegate = monitor
        motionManager.start()
        // On Simulator (and any device where motion is unavailable), MotionManager.start()
        // returns early without ever firing didChangeSettled.  Open the gate immediately so
        // frames reach the analysis pipeline.
        if !motionManager.isDeviceMotionAvailable {
            sceneGate.update(isSettled: true)
        }
        tiltMonitor = monitor
    }
}
