import SwiftUI

// MARK: - Private constants

/// Auto-expiry window for an aesthetic remark: one second past the cue-engine repeat interval
/// so the accumulator silences naturally before the coach would re-fire the same coaching line.
private let aestheticRemarkExpirySeconds = CueEngine.defaultMinRepeatIntervalSeconds + 1.0

// MARK: - AestheticExpiryHandle

/// Holds a cancellable expiry Task so `@Sendable` closures in `wireUp()` can share
/// the mutable task handle without capturing the view struct.
///
/// Declared as a `final class` (reference type) so the `@Sendable` closures that capture
/// it by value still share the same underlying storage. All mutations are dispatched on
/// `@MainActor` via `Task { @MainActor in … }` blocks.
private final class AestheticExpiryHandle: @unchecked Sendable {
    /// The pending expiry task, if any.  Always read and written on `@MainActor`.
    nonisolated(unsafe) var task: Task<Void, Never>? = nil
}

// MARK: - ContentView

/// Root view — full-screen camera preview with a toggleable debug overlay.
///
/// Owns the camera, telemetry feed, and landmark probe for the lifetime of the scene.
/// The landmark probe is wired as the downstream delegate in `TelemetryFeed` so every
/// settled camera frame flows through Vision body-pose, hand-pose, and face-mesh requests.
struct ContentView: View {

    @State private var camera = CameraCapture()
    @StateObject private var debugViewModel = DebugOverlayViewModel()
    @State private var showingVLMSettings = false

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
    @State private var landmarkOrchestrator: LandmarkOrchestrator?
    @State private var vlmOrchestrator: VLMOrchestrator?
    @State private var cueEngine: CueEngine?
    @State private var accumulator: SignalFrameAccumulator?
    @State private var voiceCoach = VoiceCoach()
    /// Pending aesthetic-remark expiry Task wrapped in a class so `@Sendable` closures
    /// can cancel and reschedule it through a shared reference.
    @State private var aestheticExpiryTask = AestheticExpiryHandle()

    var body: some View {
        ZStack {
            CameraPreviewView(camera: camera)
                .ignoresSafeArea()

            GuidesOverlayView(viewModel: debugViewModel)
                .ignoresSafeArea()

            DebugOverlayView(viewModel: debugViewModel)

            // Settings button — bottom-right corner, unobtrusive.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        showingVLMSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .imageScale(.medium)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding([.bottom, .trailing], 16)
                }
            }
        }
        .sheet(isPresented: $showingVLMSettings) {
            vlmSettingsSheet
        }
        .onAppear(perform: wireUp)
        .onChange(of: debugViewModel.isMuted) { _, muted in
            voiceCoach.isMuted = muted
        }
    }

    // MARK: - VLM Settings Sheet

    /// Inline settings sheet — no separate view file (kept minimal per M3-6 brief).
    @ViewBuilder
    private var vlmSettingsSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Privacy & Cloud Coaching")
                .font(.headline)

            Toggle(
                "Cloud composition coaching",
                isOn: Binding(
                    get: { !VLMSettings.shared.isOnDeviceOnly },
                    set: { VLMSettings.shared.isOnDeviceOnly = !$0 }
                )
            )

            Text(VLMPrivacyDisclosure.text)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
        .presentationDetents([.medium, .large])
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
        // Capture the class reference so @Sendable closures below can cancel/reschedule
        // the expiry Task through the shared handle without capturing the view struct.
        let expiryHandle = aestheticExpiryTask
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

        // Tier-2: VLMOrchestrator sits between LandmarkOrchestrator and the telemetry bridge.
        // Created before LandmarkOrchestrator so vlmOrch can be captured in the body-signal
        // callback to keep StaleSuppressor's body-hint arm updated.
        let vlmOrch = VLMOrchestrator(
            client: AnthropicVLMClient(proxyURL: VLMSettings.shared.proxyURL),
            onRequestDispatched: { [weak debugViewModel, expiryHandle] in
                // Cancel any pending expiry: the incoming response will set a fresh one.
                Task { @MainActor [weak debugViewModel, expiryHandle] in
                    expiryHandle.task?.cancel()
                    expiryHandle.task = nil
                    debugViewModel?.isVLMInFlight = true
                }
            },
            onRequestCompleted: { [weak debugViewModel] in
                Task { @MainActor [weak debugViewModel] in
                    debugViewModel?.isVLMInFlight = false
                }
            },
            onResponseDiscarded: { [weak debugViewModel] in
                Task { @MainActor [weak debugViewModel] in
                    debugViewModel?.vlmDiscardCount += 1
                }
            },
            onAestheticSignal: { [weak debugViewModel, accum, expiryHandle] signal in
                accum.update(aesthetic: signal)
                switch signal.hint {
                case .remark:
                    // Cancel any previous expiry Task and schedule a fresh one.
                    Task { @MainActor [weak debugViewModel, accum, expiryHandle] in
                        expiryHandle.task?.cancel()
                        expiryHandle.task = nil
                        debugViewModel?.aestheticRemark = signal.remark
                        let newTask = Task { [accum, weak debugViewModel] in
                            try? await Task.sleep(for: .seconds(aestheticRemarkExpirySeconds))
                            guard !Task.isCancelled else { return }
                            accum.update(aesthetic: AestheticSignal.nothingToSay)
                            await MainActor.run { [weak debugViewModel] in
                                debugViewModel?.aestheticRemark = ""
                            }
                        }
                        expiryHandle.task = newTask
                    }
                case .nothingToSay:
                    // VLM returned nothing — cancel any pending expiry (no remark to expire).
                    Task { @MainActor [weak debugViewModel, expiryHandle] in
                        expiryHandle.task?.cancel()
                        expiryHandle.task = nil
                        debugViewModel?.aestheticRemark = ""
                    }
                }
            }
        )

        // Create the landmark orchestrator. If model files are absent (e.g. Simulator),
        // try? returns nil and the pipeline degrades gracefully to the existing path.
        let orchestrator = try? LandmarkOrchestrator { [weak debugViewModel, accum, vlmOrch] signal in
            accum.update(body: signal)
            vlmOrch.update(bodyHint: signal.hint)
            let label = signal.hint == .goodBody ? "" : String(describing: signal.hint)
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.bodyHint = label
            }
        }

        let feed = debugViewModel.makeTelemetryFeed(downstream: probe)
        vlmOrch.downstream = feed.bridge

        // Wire: LandmarkOrchestrator → VLMOrchestrator → telemetry bridge.
        // When orchestrator is nil (Simulator — model files absent), vlmOrch becomes
        // the direct adapter downstream so Tier-2 wiring stays intact.
        orchestrator?.downstream = vlmOrch
        let adapterDownstream: any CameraFrameDelegate = orchestrator ?? vlmOrch
        let adapter = SceneGateAdapter(gate: sceneGate, downstream: adapterDownstream)
        camera.delegate = adapter
        feed.start()
        camera.requestPermissionAndStart()

        blurMonitor = blurMon
        exposureMonitor = exposureMon
        framingMonitor = framingMon
        landmarkProbe = probe
        landmarkOrchestrator = orchestrator
        vlmOrchestrator = vlmOrch
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
