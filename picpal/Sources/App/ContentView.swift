import AVFoundation
import SwiftUI

// MARK: - Private constants

/// Padding around button icons (used in both debug and settings buttons)
private let buttonIconPadding: CGFloat = 10

/// Padding from screen edges for control buttons
private let buttonEdgePadding: CGFloat = 16

/// SF Symbol for the reference-photo mode button.
private let referenceButtonSFSymbol: String = "photo.on.rectangle"

/// SF Symbol for the camera-flip button.
private let flipCameraButtonSFSymbol: String = "camera.rotate"

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
    @StateObject var cameraScreen = CameraScreenModel()
    @State var subjectMonitor: SubjectObservationMonitor?
    @State var previewCoordinates = CameraPreviewCoordinates()
    @State var sceneRotation = CameraSceneRotationCoordinator()
    @State var physicalOrientation: CaptureOrientation?
    @State var captureOrientation: CaptureOrientation = .portrait
    @State var previewAspectRatio: Double = 3.0 / 4.0
    @State var cameraPosition: AVCaptureDevice.Position = .back
    @State var isSwitchingCamera = false
    @AppStorage("referenceOverlayOpacity") private var referenceOpacity = 0.30
    @State private var pinchZoom = CameraPinchZoom()
    @GestureState private var isPinching = false
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
    @State var referenceCloudEnabled: Bool = false
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
    @State var predictiveCoordinator = PredictiveCoordinator.live()
    @State var batteryMonitor = BatteryMonitor()
    @State var telemetryExporter: TelemetryExporter?

    // MARK: - Manual exposure control state

    /// Screen-space point where the user last tapped to set focus/exposure.
    @State var exposureTapPoint: CGPoint?
    /// Current EV bias value driven by the slider (−2 to +2).
    @State var evBias: Float = 0
    /// Whether the focus square and EV slider are visible.
    @State var showEVControls: Bool = false
    /// Handle for the auto-dismiss task so it can be cancelled on re-interaction.
    @State var evDismissHandle = EVDismissHandle()

    @Environment(\.scenePhase) private var scenePhase
    /// Pending aesthetic-remark expiry Task wrapped in a class so `@Sendable` closures
    /// can cancel and reschedule it through a shared reference.
    @State var aestheticExpiryTask = AestheticExpiryHandle()

    var body: some View {
        GeometryReader { bounds in
            VStack(spacing: 0) {
                cameraToolbar
                CameraStage(size: CGSize(width: bounds.size.width, height: max(0, bounds.size.height - 52)),
                            aspectRatio: captureOrientation.previewAspectRatio) {
                    cameraViewport
                } controls: {
                    captureControls
                }
            }
            .frame(width: bounds.size.width, height: bounds.size.height, alignment: .top)
        }
        .background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .task(id: cameraControlsBlocked) {
            while !Task.isCancelled {
                // Also applies a deferred physical rotation after a sheet closes.
                requestPhysicalCameraRotation()
                syncReferenceAnalysis()
                await cameraScreen.tick(camera: camera, voice: voiceCoach,
                    blocked: cameraControlsBlocked, reference: referenceSession, matchState: referenceMatchState,
                    previewCoordinates: previewCoordinates)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .alert("Photo needs attention", isPresented: Binding(get: { cameraScreen.errorMessage != nil }, set: { if !$0 { cameraScreen.errorMessage = nil } })) {
            Button("OK", role: .cancel) { }
            Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
        } message: { Text(cameraScreen.errorMessage ?? "") }
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
                showReferencePicker = false
                guard let image else { return }
                clearReferenceState()
                let session = ReferenceSession(image: image)
                referenceSession = session
                referenceSessionHandle.session = session
                syncReferenceAnalysis()
                Task { await session.extractPose() }
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
                referenceCloudEnabled = true
                syncReferenceAnalysis()
            },
            onOnDeviceOnly: {
                referenceCloudConsentGiven = true
                referenceCloudEnabled = false
                syncReferenceAnalysis()
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
        .onAppear {
            wireUp()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateCaptureOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateCaptureOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: MotionManager.physicalOrientationDidChange, object: motionManager)) { notification in
            guard let orientation = notification.userInfo?["orientation"] as? CaptureOrientation else { return }
            physicalOrientation = orientation
            requestPhysicalCameraRotation()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { cameraScreen.interrupt(); voiceCoach.stop() }
            else { updateCaptureOrientation(); requestPhysicalCameraRotation() }
            syncReferenceAnalysis()
            handleScenePhaseChange(to: newPhase)
        }
        .onChange(of: debugViewModel.isMuted) { _, muted in
            voiceCoach.isMuted = muted
        }
        .onChange(of: cameraScreen.isArmed) { _, armed in
            vlmOrchestrator?.updateReferenceArmed(armed)
        }
        .onChange(of: cameraScreen.referenceGeometryRevision) { _, _ in
            referenceMatchState.reset()
            voiceCoach.stop()
            syncReferenceAnalysis()
        }
    }

    private var cameraToolbar: some View {
            HStack(spacing: 28) {
                Button { cameraScreen.flash = cameraScreen.flash == .off ? .auto : .off } label: {
                    Image(systemName: cameraScreen.flash == .off ? "bolt.slash.fill" : "bolt.fill")
                }
                .disabled(!cameraScreen.supportsFlash)
                .accessibilityLabel("Toggle automatic flash")
                Button { cameraScreen.timerSeconds = cameraScreen.timerSeconds == 0 ? 3 : 0 } label: {
                    Label(cameraScreen.timerSeconds == 0 ? "Off" : "3s", systemImage: "timer")
                }
                Spacer()
                Button { debugViewModel.isMuted.toggle() } label: {
                    Image(systemName: debugViewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .accessibilityLabel(debugViewModel.isMuted ? "Unmute coaching" : "Mute coaching")
                Button { cameraScreen.interrupt(); showingVLMSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Camera settings")
            }
            .padding(.horizontal, 24).frame(height: 52)

    }

    private var cameraViewport: some View {

            ZStack {
                CameraPreviewView(camera: camera, cameraPosition: cameraPosition, orientation: captureOrientation,
                    coordinateConverter: previewCoordinates, onInterfaceOrientationChange: { orientation in
                        updateCaptureOrientation(interfaceOrientation: orientation)
                    })
                GuidesOverlayView(viewModel: debugViewModel)
                exposureControlOverlay
                if let session = referenceSession {
                    ReferenceOverlayView(image: session.image, isMatched: referenceMatchState.isMatched,
                        isExtracting: session.isExtracting, extractionFailed: false,
                        guidanceTarget: cameraScreen.referenceDecision?.guidanceTarget,
                        opacity: referenceOpacity,
                        onDismiss: { cameraScreen.interrupt(); clearReferenceState() })
                }
                VStack {
                    VStack(spacing: 5) {
                        Text(cameraScreen.caption).font(.headline)
                        if let progress = cameraScreen.referenceDecision?.progressCaption {
                            Text(progress).font(.caption).foregroundStyle(.mint)
                        }
                        if let explanation = cameraScreen.referenceDecision?.explanation {
                            Text(explanation).font(.caption).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                        .multilineTextAlignment(.center)
                        .padding(12).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("coachingCaption")
                        .padding(.horizontal, 44).padding(.top, 12)
                    Spacer()
                    if let countdown = cameraScreen.countdown {
                        Text("\(countdown)").font(.system(size: 80, weight: .light))
                        Spacer()
                    }
                    if let notice = cameraScreen.notice { Text(notice).font(.subheadline).padding(8).background(.black.opacity(0.6), in: Capsule()) }
                    VStack(spacing: 6) {
                        if referenceSession != nil {
                            ReferenceOpacityControl(opacity: $referenceOpacity,
                                referenceDescription: referenceSession.map { $0.image.size.width == $0.image.size.height ? "Square reference" :
                                    $0.image.size.width > $0.image.size.height ? "Landscape reference" : "Portrait reference" } ?? "Reference")
                        }
                        CameraZoomControl(zoom: cameraScreen.zoom, minimum: cameraScreen.minZoom,
                            maximum: cameraScreen.maxZoom, multiplier: cameraScreen.displayZoomMultiplier,
                            disabled: zoomControlsBlocked) { value in
                                cameraScreen.setZoom(value, camera: camera)
                            }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
                #if DEBUG
                DebugOverlayView(viewModel: debugViewModel, onLongPress: { cameraScreen.interrupt(); showTuningPanel = true })
                    .padding(.trailing, referenceSession == nil ? 0 : 48)
                #endif
            }
            .clipped()
            .simultaneousGesture(MagnifyGesture()
                .updating($isPinching) { _, active, _ in active = true }
                .onChanged { value in
                    guard !zoomControlsBlocked else { pinchZoom.cancel(); return }
                    if let zoom = pinchZoom.update(magnification: value.magnification,
                        current: cameraScreen.zoom, minimum: cameraScreen.minZoom, maximum: cameraScreen.maxZoom) {
                        cameraScreen.setZoom(zoom, camera: camera)
                    }
                }
                .onEnded { _ in pinchZoom.reset() })
            .onChange(of: isPinching) { _, active in if !active { pinchZoom.reset() } }
            .onChange(of: zoomControlsBlocked) { _, blocked in if blocked && isPinching { pinchZoom.cancel() } }
            .onChange(of: cameraPosition) { _, _ in if isPinching { pinchZoom.cancel() } }
            .onChange(of: captureOrientation) { _, _ in if isPinching { pinchZoom.cancel() } }
            .background(GeometryReader { geometry in
                Color.clear.onAppear { updatePreviewAspect(geometry.size) }
                    .onChange(of: geometry.size) { _, size in updatePreviewAspect(size) }
            })

    }

    private var zoomControlsBlocked: Bool {
        cameraControlsBlocked || cameraScreen.isBusy || !cameraScreen.isReady || cameraScreen.pendingPhoto != nil
    }

    private var captureControls: some View {

            VStack(spacing: captureOrientation == .portrait ? 16 : 8) {
                HStack(spacing: 28) {
                    ForEach(ShotStyle.allCases, id: \.self) { style in
                        Button(style == .fullBody ? "FULL BODY" : "PORTRAIT") {
                            cameraScreen.style = style
                            cameraScreen.interrupt()
                        }
                        .foregroundStyle(cameraScreen.style == style ? .yellow : .white.opacity(0.6))
                    }
                }.font(.caption.bold())
                HStack {
                    Button {
                        guard !isSwitchingCamera else { return }
                        isSwitchingCamera = true
                        previewCoordinates.beginSwitch()
                        cameraScreen.interrupt()
                        referenceMatchState.reset()
                        voiceCoach.stop()
                        Task { @MainActor in
                            let committedPosition = await camera.switchCamera()
                            cameraPosition = committedPosition
                            cameraScreen.useAutomaticFocus(camera: camera)
                            cameraScreen.invalidateReferenceGeometry()
                            previewCoordinates.endSwitch()
                            isSwitchingCamera = false
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2)
                            .frame(width: 52, height: 52).background(.white.opacity(0.12), in: Circle())
                    }
                    .disabled(cameraScreen.isBusy || isSwitchingCamera)
                    .accessibilityLabel("Switch camera")
                    Spacer()
                    Button { cameraScreen.capture(camera: camera) } label: {
                        ZStack {
                            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                            Circle().fill(.white).frame(width: 64, height: 64)
                            if cameraScreen.isBusy { ProgressView().tint(.black) }
                            if cameraScreen.isArmed {
                                Circle().stroke(.yellow, lineWidth: 3)
                                    .frame(width: 84, height: 84).rotationEffect(.degrees(-90))
                            }
                        }
                    }
                    .disabled(!cameraScreen.isReady || cameraScreen.isBusy || cameraScreen.pendingPhoto != nil || isSwitchingCamera)
                    .accessibilityLabel("Take photo").accessibilityIdentifier("photoShutter")
                    Spacer()
                    Button { cameraScreen.interrupt(); showReferencePicker = true } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.15))
                            if let image = referenceSession?.image ?? cameraScreen.lastPhoto {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else { Image(systemName: "photo.on.rectangle").font(.title2) }
                        }.frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("Choose reference from Photos").accessibilityIdentifier("referencePhotos")
                }.padding(.horizontal, 30)
                Button { cameraScreen.toggleAutoCapture() } label: {
                    Label(cameraScreen.isArmed ? "Stop · \(cameraScreen.sessionPhotoCount) photos" : "Auto capture", systemImage: cameraScreen.isArmed ? "stop.circle.fill" : "viewfinder")
                        .font(.subheadline).foregroundStyle(cameraScreen.isArmed ? .yellow : .white)
                }.disabled(isSwitchingCamera || (!cameraScreen.isArmed && (cameraScreen.isBusy || cameraScreen.pendingPhoto != nil)))
                if cameraScreen.pendingPhoto != nil, !cameraScreen.isBusy {
                    Button("Photo not saved — retry saving") { cameraScreen.retrySave() }.font(.footnote)
                }
            }
            .padding(.top, 16).padding(.bottom, 12)
    }

    var cameraControlsBlocked: Bool {
        var blocked = isSwitchingCamera || scenePhase != .active || showConsentSheet || showingVLMSettings || showReferencePicker || showSurvey
        #if DEBUG
        blocked = blocked || showSessionKit || showTuningPanel
        #endif
        return blocked || (referenceSession != nil && !referenceCloudConsentGiven && !VLMSettings.shared.isOnDeviceOnly)
    }

    // MARK: - VLM Settings Sheet

    /// Inline settings sheet — no separate view file (kept minimal per M3-6 brief).
    @ViewBuilder
    private var vlmSettingsSheet: some View {
        CloudCoachingSettingsView {
            // A new endpoint or privacy choice invalidates pending evidence.
            referenceCloudEnabled = false
            referenceCloudConsentGiven = false
            cameraScreen.interrupt()
            voiceCoach.stop()
            syncReferenceAnalysis()
        }
        .presentationDetents([.medium, .large])
    }
}

/// Keeps the preview's identity (and its AVCaptureSession connection) stable while
/// changing layout. Explicit bounds prevent overlay content from enlarging the feed.
struct CameraStage<Preview: View, Controls: View>: View {
    let size: CGSize
    let aspectRatio: CGFloat
    @ViewBuilder var preview: () -> Preview
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        let landscape = size.width > size.height
        let available = CGSize(width: max(0, size.width - (landscape ? 272 : 0)),
                               height: max(0, size.height - (landscape ? 0 : 200)))
        let width = min(available.width, available.height * aspectRatio)
        let height = width / aspectRatio
        let layout = landscape ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            preview()
                .frame(width: width, height: height)
                .clipped()
            controls()
                .frame(width: landscape ? 260 : size.width)
        }
        .frame(width: size.width, height: size.height, alignment: landscape ? .center : .top)
    }
}

struct ReferenceOpacityControl: View {
    @Binding var opacity: Double
    var referenceDescription = "Reference"
    var body: some View {
        VStack(spacing: 0) {
            Text(referenceDescription).font(.caption2)
            HStack(spacing: 8) {
                Image(systemName: "square.on.square")
                Slider(value: $opacity, in: 0...1)
                .accessibilityLabel("Reference opacity")
                .accessibilityValue("\(Int(opacity * 100)) percent")
                Text("\(Int(opacity * 100))%").font(.caption.monospacedDigit()).frame(width: 36)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: 280)
        .background(.black.opacity(0.65), in: Capsule())
    }
}

/// These are zoom positions within the active camera's range, not claims about lenses.
struct CameraZoomControl: View {
    let zoom: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let multiplier: CGFloat
    var disabled = false
    var setZoom: (CGFloat) -> Void
    @State var expanded = false

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                ForEach(CameraZoomStops.rawValues(minimum: minimum, maximum: maximum, multiplier: multiplier), id: \.self) { value in
                    Button { setZoom(value) } label: {
                        Text(CameraZoomStops.label(value * multiplier))
                            .font(.caption.bold()).monospacedDigit()
                            .frame(minWidth: 36, minHeight: 36)
                            .foregroundStyle(abs(zoom - value) < 0.04 ? .yellow : .white)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Zoom \(CameraZoomStops.label(value * multiplier))")
                    .highPriorityGesture(LongPressGesture().onEnded { _ in expanded = true })
                }
                Button { expanded.toggle() } label: {
                    Text(CameraZoomStops.label(zoom * multiplier))
                        .font(.caption.monospacedDigit()).foregroundStyle(.yellow)
                        .frame(minWidth: 44, minHeight: 36)
                }
                .accessibilityLabel("Fine zoom adjustment")
                .accessibilityValue(CameraZoomStops.label(zoom * multiplier))
                .highPriorityGesture(LongPressGesture().onEnded { _ in expanded = true })
            }
            if expanded {
                Slider(value: Binding(get: { Double(zoom) }, set: { setZoom(CGFloat($0)) }),
                       in: Double(minimum)...max(Double(minimum) + 0.001, Double(maximum)))
                    .frame(maxWidth: 240).accessibilityLabel("Zoom")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 24))
        .disabled(disabled || maximum <= minimum)
    }
}

enum CameraZoomStops {
    static func rawValues(minimum: CGFloat, maximum: CGFloat, multiplier: CGFloat) -> [CGFloat] {
        guard minimum.isFinite, maximum.isFinite, multiplier.isFinite,
              minimum > 0, maximum >= minimum, multiplier > 0 else { return [] }
        var values = [minimum]
        for displayed: CGFloat in [1, 2, 3] {
            let raw = displayed / multiplier
            if raw >= minimum, raw <= maximum, !values.contains(where: { abs($0 - raw) < 0.04 }) {
                values.append(raw)
            }
        }
        return values.sorted()
    }

    static func label(_ displayed: CGFloat) -> String {
        String(format: "%.1f×", displayed)
    }
}

struct CameraPinchZoom {
    private(set) var baseline: CGFloat?
    private var cancelled = false

    mutating func update(magnification: CGFloat, current: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat? {
        guard !cancelled, magnification.isFinite, magnification > 0,
              current.isFinite, minimum > 0, maximum >= minimum else { return nil }
        if baseline == nil { baseline = current }
        return min(maximum, max(minimum, (baseline ?? current) * magnification))
    }

    mutating func cancel() { cancelled = true }
    mutating func reset() { baseline = nil; cancelled = false }
}
