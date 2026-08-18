import SwiftUI

// MARK: - Private constants

/// Padding around button icons (used in both debug and settings buttons)
private let buttonIconPadding: CGFloat = 10

/// Padding from screen edges for control buttons
private let buttonEdgePadding: CGFloat = 16

/// SF Symbol for the reference-photo mode button.
private let referenceButtonSFSymbol: String = "photo.on.rectangle"

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
    @State private var showReferencePicker: Bool = false
    @State private var showConsentSheet: Bool
    @State var showSurvey: Bool = false
    @State var surveyShownThisSession: Bool = false

    // MARK: - Reference mode state

    /// The active reference session. Non-nil while the user has picked a reference photo.
    /// Internal (not private) so ContentView+Reference.swift can mutate it.
    @State var referenceSession: ReferenceSession?
    /// Whether the user has consented to cloud calls for the current reference session.
    @State var referenceCloudConsentGiven: Bool = false
    /// Stable class reference for the current session; captured by wireUp() closures.
    @State var referenceSessionHandle = ReferenceSessionHandle()
    /// Per-frame match tracking. @StateObject so SwiftUI observes published changes.
    @StateObject var referenceMatchState = ReferenceMatchState()
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

            // Reference ghost overlay — rendered between debug layer and controls.
            if let session = referenceSession {
                ReferenceOverlayView(
                    image: session.image,
                    isMatched: referenceMatchState.isMatched,
                    isExtracting: session.isExtracting,
                    onDismiss: clearReferenceState
                )
            }

            // Control buttons — bottom row.
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
                    // Reference mode button — bottom-right, left of the settings button.
                    Button {
                        showReferencePicker = true
                    } label: {
                        Image(systemName: referenceButtonSFSymbol)
                            .imageScale(.medium)
                            .padding(buttonIconPadding)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding([.bottom], buttonEdgePadding)
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
        // M5.5-5: Reference picker — creates a ReferenceSession and starts extraction.
        .sheet(isPresented: $showReferencePicker) {
            ReferencePhotoPicker { image in
                guard let image else { return }
                let session = ReferenceSession(image: image)
                referenceSession = session
                referenceSessionHandle.session = session
                vlmOrchestrator?.referenceImage = image
                Task { await session.extractPose() }
                showReferencePicker = false
            }
        }
        // M5.5-5: One-per-session consent alert before cloud reference calls.
        .referenceConsentAlert(
            isPresented: Binding(
                get: {
                    referenceSession != nil
                        && !referenceCloudConsentGiven
                        && !VLMSettings.shared.isOnDeviceOnly
                },
                set: { _ in }
            ),
            onEnableForSession: {
                referenceCloudConsentGiven = true
                vlmOrchestrator?.referenceModeConsented = true
            },
            onOnDeviceOnly: {
                referenceCloudConsentGiven = true
            }
        )
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
