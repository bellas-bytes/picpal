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

    /// The active coaching cue selected by the cue engine (placeholder: "—").
    ///
    /// Updated after every signal tick. "—" means silence (no active cue).
    @Published var activeCue: String = "—"

    /// Whether voice output is muted (placeholder: false).
    ///
    /// Toggled by the mute button in `DebugOverlayView`. Changes propagate to
    /// `VoiceCoach.isMuted` via `ContentView`'s `onChange` observer.
    @Published var isMuted: Bool = false

    // MARK: - Guides overlay fields

    /// Whether the device is currently within the level dead-zone (placeholder: false).
    @Published var isLevel: Bool = false

    /// Normalized bounding box of the primary subject in Vision coords (origin bottom-left).
    /// `nil` when no subject is detected (placeholder: nil).
    @Published var subjectBox: CGRect? = nil

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
                }
            },
            frameTimer: frameTimer,
            downstream: downstream,
            notificationCenter: notificationCenter
        )
    }
}
