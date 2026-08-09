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

    /// Measured frames per second (placeholder: 0).
    @Published var framesPerSecond: Double = 0

    /// Thermal state description (placeholder: "nominal").
    @Published var thermalState: String = "nominal"

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
        notificationCenter: NotificationCenter = .default
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
            frameTimer: frameTimer,
            notificationCenter: notificationCenter
        )
    }
}
