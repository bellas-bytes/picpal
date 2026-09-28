import CoreGraphics
import Foundation

/// Holds the display values shown by `DebugOverlayView`.
///
/// All properties start at placeholder values. Upstream tasks update them by
/// assigning to the published properties. Callers must always mutate on the main actor.
@MainActor
final class DebugOverlayViewModel: ObservableObject {

    // MARK: - Published debug fields

    /// Device tilt in degrees (placeholder: 0).
    @Published var tiltDegrees: Double = 0

    /// Laplacian blur score (placeholder: 0).
    @Published var blurScore: Double = 0

    /// Human-readable exposure level (placeholder: "—").
    @Published var exposureLevel: String = "—"

    /// Framing hint label (placeholder: "—").
    @Published var framingHint: String = "—"

    /// Measured frames per second (placeholder: 0).
    @Published var framesPerSecond: Double = 0

    /// Thermal state description (placeholder: "nominal").
    @Published var thermalState: String = "nominal"

    /// Cumulative count of frames that exceeded the 16.67 ms budget (placeholder: 0).
    @Published var dropCount: Int = 0

    /// Rolling mean frame-processing time in milliseconds (placeholder: 0.0).
    @Published var meanFrameMs: Double = 0.0

    // MARK: - Landmark probe fields

    /// Rolling mean body-pose inference time in milliseconds (placeholder: 0.0).
    @Published var bodyPoseMs: Double = 0.0

    /// Rolling mean hand-pose inference time in milliseconds (placeholder: 0.0).
    @Published var handPoseMs: Double = 0.0

    /// Rolling mean face-mesh inference time in milliseconds (placeholder: 0.0).
    @Published var faceMeshMs: Double = 0.0

    /// Rolling mean combined Vision total in milliseconds (placeholder: 0.0).
    @Published var landmarkCombinedMs: Double = 0.0

    /// Body-framing hint from the M2 signal pipeline (placeholder: "").
    ///
    /// Empty string means no active body cue (good body state or no person detected).
    @Published var bodyHint: String = ""

    /// Counts and association state from the independent live subject detectors.
    @Published var subjectDetectionSummary: String = "—"

    /// The active coaching cue selected by the cue engine (placeholder: "—").
    ///
    /// Retained briefly across cooldown ticks so it can be read.
    @Published var activeCue: String = "—"

    private var lastCoachingCueAt: Date?
    private static let cueDisplaySeconds: TimeInterval = 4

    func receiveCoachingCue(_ cue: Cue?, at date: Date = Date()) {
        if let cue {
            activeCue = cue.text
            lastCoachingCueAt = date
        } else if let lastCoachingCueAt,
                  date.timeIntervalSince(lastCoachingCueAt) >= Self.cueDisplaySeconds {
            activeCue = "—"
            self.lastCoachingCueAt = nil
        }
    }

    /// Whether voice output is muted (placeholder: false).
    ///
    /// Toggled by the mute button in `DebugOverlayView`. Changes propagate to
    /// `VoiceCoach.isMuted` via `ContentView`'s `onChange` observer.
    @Published var isMuted: Bool = false
    @Published var isShowingDiagnostics: Bool = false

    // MARK: - Guides overlay fields

    /// Whether the device is currently within the level dead-zone (placeholder: false).
    @Published var isLevel: Bool = false

    /// Normalized bounding box of the primary subject in Vision coords (origin bottom-left).
    /// `nil` when no subject is detected (placeholder: nil).
    @Published var subjectBox: CGRect? = nil

    // MARK: - VLM fields

    /// Active aesthetic remark from the VLM tier (placeholder: "").
    ///
    /// Empty string means no active remark (either `.nothingToSay` or no response yet).
    @Published var aestheticRemark: String = ""

    /// Whether a VLM request is currently in flight (placeholder: false).
    ///
    /// Set to `true` when a request is dispatched; cleared when the response arrives
    /// (or when the request times out / is suppressed as stale).
    @Published var isVLMInFlight: Bool = false

    /// 95th-percentile frame-processing time in milliseconds (placeholder: 0.0).
    /// Updated each frame from `TelemetryFeed.onFrameStats`.
    @Published var p95FrameMs: Double = 0.0

    /// Count of VLM responses discarded by `StaleSuppressor` (placeholder: 0).
    /// Incremented via `VLMOrchestrator.onResponseDiscarded`.
    @Published var vlmDiscardCount: Int = 0

    // MARK: - Export callback

    /// Called when the user triggers an on-demand telemetry export (e.g. triple-tap in debug).
    ///
    /// Not `@Published` — this is a callback, not state.
    var onExportTelemetry: (() -> Void)?

    // MARK: - Telemetry wiring

    /// Creates a `TelemetryFeed` wired to update `framesPerSecond` and `thermalState`.
    ///
    /// Retain the returned feed for the lifetime of the session and wire its bridge into
    /// the camera pipeline:
    /// ```swift
    /// let feed = viewModel.makeTelemetryFeed()
    /// camera.delegate = feed.bridge
    /// feed.start()
    /// ```
    ///
    /// - Parameters:
    ///   - frameTimer: Override for testing.
    ///   - notificationCenter: Override for testing.
    func makeTelemetryFeed(
        frameTimer: FrameTimer = FrameTimer(),
        notificationCenter: NotificationCenter = .default,
        downstream: (any CameraFrameDelegate)? = nil
    ) -> TelemetryFeed {
        TelemetryFeed(
            onFPS: { [weak self] fps in
                Task { @MainActor [weak self] in
                    self?.framesPerSecond = fps
                }
            },
            onThermal: { [weak self] event in
                let label = ThermalMonitor.stateName(for: event.state)
                Task { @MainActor [weak self] in
                    self?.thermalState = label
                }
            },
            onFrameStats: { [weak self] stats in
                Task { @MainActor [weak self] in
                    self?.dropCount = stats.dropCount
                    self?.meanFrameMs = stats.meanMs
                    self?.p95FrameMs = stats.p95Ms
                }
            },
            frameTimer: frameTimer,
            downstream: downstream,
            notificationCenter: notificationCenter
        )
    }
}
