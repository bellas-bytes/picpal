import UIKit
import Foundation

/// A summary of battery drain measured across a recording session.
public struct BatteryReport: Sendable, Equatable, Encodable {
    /// Battery level at session start, in [0, 1] (−1 if the device cannot report level).
    public let startLevel: Float
    /// Battery level at session end, in [0, 1] (−1 if the device cannot report level).
    public let endLevel: Float
    /// Session wall-clock duration in seconds.
    public let duration: TimeInterval

    /// Estimated drain as a percentage [0, 100]. Clamped to zero for charging scenarios.
    public var drainPercentage: Float {
        max(0, (startLevel - endLevel) * 100)
    }
}

/// Abstracts UIDevice battery APIs for testability.
///
/// Inject a mock conformance in unit tests to avoid UIDevice hardware dependencies.
@MainActor
public protocol BatteryDevice: AnyObject {
    var batteryLevel: Float { get }
    var isBatteryMonitoringEnabled: Bool { get set }
}

// MARK: - Production implementation

/// `@MainActor` wrapper around `UIDevice.current` that satisfies `BatteryDevice`.
@MainActor
final class LiveBatteryDevice: BatteryDevice {
    var batteryLevel: Float { UIDevice.current.batteryLevel }
    var isBatteryMonitoringEnabled: Bool {
        get { UIDevice.current.isBatteryMonitoringEnabled }
        set { UIDevice.current.isBatteryMonitoringEnabled = newValue }
    }
}

// MARK: - BatteryMonitor

/// Samples battery level at session start and end to estimate drain over a run.
///
/// Must be used from the **main actor**; `UIDevice` battery APIs require main-thread access.
///
/// ## Testing
/// Pass a `MockBatteryDevice` conforming to `BatteryDevice` to exercise `BatteryReport`
/// calculations without UIDevice hardware. On the simulator, `UIDevice.batteryLevel`
/// always returns −1 (unavailable).
///
/// ## Usage
/// ```swift
/// monitor.startSession()          // begin of camera session
/// // ... run for 3–5 minutes ...
/// let report = monitor.endSession()
/// ```
@MainActor
public final class BatteryMonitor {

    // MARK: - State

    private let device: any BatteryDevice
    private var startLevel: Float?
    private var startTime: Date?

    // MARK: - Init

    /// Creates a `BatteryMonitor` backed by the real `UIDevice` singleton.
    public init() {
        self.device = LiveBatteryDevice()
    }

    /// Creates a `BatteryMonitor` with an injectable `BatteryDevice` — for testing.
    init(device: any BatteryDevice) {
        self.device = device
    }

    // MARK: - Session lifecycle

    /// Enable battery monitoring and record the starting level.
    public func startSession() {
        device.isBatteryMonitoringEnabled = true
        startLevel = device.batteryLevel
        startTime = Date()
    }

    /// Record the ending level, disable monitoring, and return a drain report.
    ///
    /// Returns `nil` if `startSession()` was never called.
    @discardableResult
    public func endSession() -> BatteryReport? {
        defer {
            device.isBatteryMonitoringEnabled = false
            startLevel = nil
            startTime = nil
        }
        guard let start = startLevel, let startTime else { return nil }
        return BatteryReport(
            startLevel: start,
            endLevel: device.batteryLevel,
            duration: Date().timeIntervalSince(startTime)
        )
    }
}
