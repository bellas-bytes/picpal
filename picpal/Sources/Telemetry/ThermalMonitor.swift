import Foundation
import os

/// A timestamped observation of a thermal state transition.
public struct ThermalEvent: Sendable {
    /// The thermal state at the time of the transition.
    public let state: ProcessInfo.ThermalState
    /// When the transition was observed.
    public let timestamp: Date
}

extension ThermalEvent: Encodable {
    private enum CodingKeys: String, CodingKey { case state, timestamp }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ThermalMonitor.stateName(for: state), forKey: .state)
        try container.encode(timestamp, forKey: .timestamp)
    }
}

/// Receives thermal state transitions from a `ThermalMonitor`.
public protocol ThermalMonitorDelegate: AnyObject {
    /// Invoked on an unspecified thread. Implementations must dispatch to their own
    /// isolation context (e.g., `Task { @MainActor in ... }`) as needed.
    func thermalMonitor(_ monitor: ThermalMonitor, didObserve event: ThermalEvent)
}

/// Monitors `ProcessInfo.thermalState` and emits a `ThermalEvent` on each transition.
///
/// ## Testing note
/// `ProcessInfo.thermalStateDidChangeNotification` is only posted on a **real device** —
/// the iOS Simulator does not fire thermal state notifications. Inject a custom
/// `NotificationCenter` in unit tests and post synthetic notifications to exercise the
/// delegate path. `handleThermalChange()` is `internal` for the same purpose.
///
/// ## Thread safety
/// `ThermalMonitor` is `@unchecked Sendable`. The `observers` array is protected by
/// `observersLock` (an `NSLock`). NSObjectProtocol tokens are not `Sendable`, so
/// `OSAllocatedUnfairLock<[NSObjectProtocol]>` cannot be used — `NSLock` is the
/// equivalent safe choice for non-Sendable stored state.
public final class ThermalMonitor: @unchecked Sendable {

    // MARK: - Dependencies

    private let notificationCenter: NotificationCenter
    private let logger = Logger(subsystem: "com.picpal", category: "ThermalMonitor")
    private weak var delegate: (any ThermalMonitorDelegate)?

    // MARK: - Observer tokens (NSLock + nonisolated(unsafe) for non-Sendable tokens)

    private let observersLock = NSLock()
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    // MARK: - Init

    public init(
        delegate: (any ThermalMonitorDelegate)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.delegate = delegate
        self.notificationCenter = notificationCenter
    }

    deinit { stop() }

    // MARK: - Lifecycle

    /// Begin observing `ProcessInfo.thermalStateDidChangeNotification`.
    public func start() {
        let token = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleThermalChange()
        }
        observersLock.lock()
        observers.append(token)
        observersLock.unlock()
    }

    /// Stop observing and remove all notification observers.
    public func stop() {
        observersLock.lock()
        let tokens = observers
        observers.removeAll()
        observersLock.unlock()
        tokens.forEach { notificationCenter.removeObserver($0) }
    }

    // MARK: - Internal — accessible via @testable import

    /// Reads the current thermal state and emits a `ThermalEvent` to the delegate.
    ///
    /// In tests, trigger this by posting a synthetic
    /// `ProcessInfo.thermalStateDidChangeNotification` to the injected center.
    func handleThermalChange() {
        let event = ThermalEvent(
            state: ProcessInfo.processInfo.thermalState,
            timestamp: Date()
        )
        logger.info("Thermal state → \(Self.stateName(for: event.state), privacy: .public)")
        delegate?.thermalMonitor(self, didObserve: event)
    }

    // MARK: - Public helpers

    /// Returns a human-readable display name for a `ProcessInfo.ThermalState`.
    public static func stateName(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
