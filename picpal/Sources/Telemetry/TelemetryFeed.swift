import Foundation

/// Coordinates `PipelineTelemetryBridge` and `ThermalMonitor`, surfacing live
/// `framesPerSecond` and `thermalState` values via caller-supplied callbacks.
///
/// The telemetry module stays dependency-free from the UI layer — callbacks dispatch
/// to the appropriate isolation context at the call site.
///
/// ## Usage (composition root)
/// ```swift
/// let feed = TelemetryFeed(
///     onFPS: { fps in
///         Task { @MainActor in viewModel.framesPerSecond = fps }
///     },
///     onThermal: { event in
///         Task { @MainActor in viewModel.thermalState = ThermalMonitor.stateName(for: event.state) }
///     }
/// )
/// camera.delegate = feed.bridge   // plug into camera pipeline
/// feed.start()                     // begin thermal monitoring
/// ```
///
/// `TelemetryFeed` is `@unchecked Sendable`; it owns immutable sub-components and
/// its retained `ThermalEventHandler` is itself `@unchecked Sendable`.
public final class TelemetryFeed: @unchecked Sendable {

    // MARK: - Components

    /// Camera-pipeline delegate. Set `CameraCapture.delegate = feed.bridge` to activate.
    public let bridge: PipelineTelemetryBridge

    /// The thermal state monitor; started and stopped via `TelemetryFeed.start/stop()`.
    public let thermalMonitor: ThermalMonitor

    // MARK: - Internal retention

    /// Retained to keep `ThermalMonitor`'s `weak var delegate` alive for the feed's lifetime.
    private let thermalHandler: ThermalEventHandler

    // MARK: - Init

    /// Create a `TelemetryFeed` with injectable callbacks and components.
    ///
    /// - Parameters:
    ///   - onFPS: Called (on an unspecified thread) with the measured FPS each second.
    ///            Dispatch to `@MainActor` inside this closure to update UI.
    ///   - onThermal: Called (on an unspecified thread) on every thermal state change.
    ///                Dispatch to `@MainActor` inside this closure to update UI.
    ///   - frameTimer: Frame timer override for testing.
    ///   - downstream: Next pipeline delegate (nil until the analysis stage is added).
    ///   - notificationCenter: Notification center override for testing.
    public init(
        onFPS: @escaping @Sendable (Double) -> Void,
        onThermal: @escaping @Sendable (ThermalEvent) -> Void,
        frameTimer: FrameTimer = FrameTimer(),
        downstream: (any CameraFrameDelegate)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        let bridge = PipelineTelemetryBridge(
            frameTimer: frameTimer,
            downstream: downstream,
            onFPSUpdate: onFPS
        )
        let handler = ThermalEventHandler(callback: onThermal)
        let monitor = ThermalMonitor(delegate: handler, notificationCenter: notificationCenter)

        self.bridge = bridge
        self.thermalHandler = handler
        self.thermalMonitor = monitor
    }

    // MARK: - Lifecycle

    /// Start thermal state monitoring.
    public func start() { thermalMonitor.start() }

    /// Stop thermal state monitoring.
    public func stop() { thermalMonitor.stop() }
}

// MARK: - Internal helper

/// Bridges `ThermalMonitorDelegate` to a stored `@Sendable` closure.
///
/// `TelemetryFeed` retains this object so that `ThermalMonitor`'s `weak var delegate`
/// stays alive for the full lifetime of the feed.
final class ThermalEventHandler: @unchecked Sendable, ThermalMonitorDelegate {

    private let callback: @Sendable (ThermalEvent) -> Void

    init(callback: @escaping @Sendable (ThermalEvent) -> Void) {
        self.callback = callback
    }

    func thermalMonitor(_ monitor: ThermalMonitor, didObserve event: ThermalEvent) {
        callback(event)
    }
}
