import SwiftUI

// MARK: - Private constants

/// Padding around button icons (used in both debug and settings buttons)
private let buttonIconPadding: CGFloat = 10

/// Padding from screen edges for control buttons
private let buttonEdgePadding: CGFloat = 16

// MARK: - ContentView

/// Root view — full-screen camera preview with a toggleable debug overlay.
///
/// Owns the camera, telemetry feed, and landmark probe for the lifetime of the scene.
/// The landmark probe is wired as the downstream delegate in `TelemetryFeed` so every
/// settled camera frame flows through Vision body-pose, hand-pose, and face-mesh requests.
///
/// Session lifecycle (scene-phase handling, telemetry export, composition root) lives in
/// `ContentView+Session.swift` to keep this file under the 300-line limit.
struct ContentView: View {

    @State var camera = CameraCapture()
    @StateObject var debugViewModel = DebugOverlayViewModel()
    @State private var showingVLMSettings = false
    @State private var showConsentSheet: Bool
    @State var showSurvey: Bool = false
    @State var surveyShownThisSession: Bool = false
    #if DEBUG
    @State private var showSessionKit = false
    @State private var showTuningPanel = false
    #endif

    init() {
        _showConsentSheet = State(initialValue: !ConsentGate.isConsentGiven())
    }

    // Retained for the lifetime of the view.
    @State var telemetryFeed: TelemetryFeed?
    @State var landmarkProbe: VisionLandmarkProbe?
    @State var blurMonitor: BlurMonitor?
    @State var exposureMonitor: ExposureMonitor?
    @State var framingMonitor: FramingMonitor?
    @State var motionManager = MotionManager()
    @State var tiltMonitor: TiltMonitor?
    @State var sceneGate = SceneGate()
    @State var sceneGateAdapter: SceneGateAdapter?
    @State var landmarkOrchestrator: LandmarkOrchestrator?
    @State var vlmOrchestrator: VLMOrchestrator?
    @State var cueEngine: CueEngine?
    @State var accumulator: SignalFrameAccumulator?
    @State var voiceCoach = VoiceCoach()
    @State var cueLogger: CueLogger?
    @State var settleEventTimer: SettleEventTimer?
    @State var batteryMonitor = BatteryMonitor()
    @State var telemetryExporter: TelemetryExporter?

    @Environment(\.scenePhase) private var scenePhase
    /// Pending aesthetic-remark expiry Task wrapped in a class so `@Sendable` closures
    /// can cancel and reschedule it through a shared reference.
    @State var aestheticExpiryTask = AestheticExpiryHandle()

    var body: some View {
        ZStack {
            CameraPreviewView(camera: camera)
                .ignoresSafeArea()

            GuidesOverlayView(viewModel: debugViewModel)
                .ignoresSafeArea()

            #if DEBUG
            DebugOverlayView(viewModel: debugViewModel, onLongPress: { showTuningPanel = true })
            #else
            DebugOverlayView(viewModel: debugViewModel)
            #endif

            // Settings button — bottom-right corner, unobtrusive.
            VStack {
                Spacer()
                HStack {
                    #if DEBUG
                    // Session kit button — bottom-left corner, debug only.
                    Button {
                        showSessionKit = true
                    } label: {
                        Image(systemName: "list.clipboard")
                            .imageScale(.medium)
                            .padding(buttonIconPadding)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding([.bottom, .leading], buttonEdgePadding)
                    #endif
                    Spacer()
                    Button {
                        showingVLMSettings = true
                    } label: {
                        Image(systemName: "gear")
                            .imageScale(.medium)
                            .padding(buttonIconPadding)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding([.bottom, .trailing], buttonEdgePadding)
                }
            }
        }
        .sheet(isPresented: $showingVLMSettings) {
            vlmSettingsSheet
        }
        .fullScreenCover(isPresented: $showConsentSheet) {
            ConsentSheet { cloudEnabled in
                ConsentGate.recordConsent(cloudEnabled: cloudEnabled)
                showConsentSheet = false
            }
        }
        .sheet(isPresented: $showSurvey) {
            PostSessionSurveySheet { response in
                showSurvey = false
                if let response {
                    PostSessionSurvey.record(response: response)
                    exportSnapshot(surveyResponse: response)
                }
                // Skip: no record, no export (the background export already fired)
            }
        }
        #if DEBUG
        .sheet(isPresented: $showSessionKit) {
            SessionTaskOverlay(tasks: SessionTaskScript.m4Tasks) {
                showSessionKit = false
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showTuningPanel) {
            TuningPanel()
                .presentationDetents([.medium, .large])
        }
        #endif
        .onAppear(perform: wireUp)
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(to: newPhase)
        }
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
}
