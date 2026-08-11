import Testing
@testable import PicPal

// MARK: - BatteryReport struct tests

@Suite("BatteryReport")
struct BatteryReportTests {

    @Test("drainPercentage is correct for positive drain")
    func drainPercentageForPositiveDrain() {
        let report = BatteryReport(startLevel: 0.80, endLevel: 0.60, duration: 180)
        #expect(abs(report.drainPercentage - 20.0) < 0.001)
    }

    @Test("drainPercentage is zero when levels are equal")
    func drainPercentageZeroForEqualLevels() {
        let report = BatteryReport(startLevel: 0.75, endLevel: 0.75, duration: 60)
        #expect(report.drainPercentage == 0.0)
    }

    @Test("drainPercentage is clamped to zero during charging")
    func drainPercentageClampedForCharging() {
        // endLevel > startLevel indicates the device was charging
        let report = BatteryReport(startLevel: 0.50, endLevel: 0.70, duration: 120)
        #expect(report.drainPercentage == 0.0)
    }

    @Test("drainPercentage is zero when both levels are unavailable (-1)")
    func drainPercentageForUnavailableLevel() {
        // UIDevice returns −1 when battery monitoring is disabled (e.g., simulator)
        let report = BatteryReport(startLevel: -1, endLevel: -1, duration: 60)
        #expect(report.drainPercentage == 0.0)
    }

    @Test("duration is stored as supplied")
    func durationStoredCorrectly() {
        let report = BatteryReport(startLevel: 0.9, endLevel: 0.8, duration: 300)
        #expect(report.duration == 300)
    }

    @Test("Equatable: same values are equal")
    func equalityHoldsForSameValues() {
        let a = BatteryReport(startLevel: 0.8, endLevel: 0.7, duration: 120)
        let b = BatteryReport(startLevel: 0.8, endLevel: 0.7, duration: 120)
        #expect(a == b)
    }

    @Test("Equatable: different endLevel is not equal")
    func inequalityForDifferentEndLevel() {
        let a = BatteryReport(startLevel: 0.8, endLevel: 0.7, duration: 120)
        let b = BatteryReport(startLevel: 0.8, endLevel: 0.6, duration: 120)
        #expect(a != b)
    }

    @Test("Equatable: different duration is not equal")
    func inequalityForDifferentDuration() {
        let a = BatteryReport(startLevel: 0.8, endLevel: 0.7, duration: 60)
        let b = BatteryReport(startLevel: 0.8, endLevel: 0.7, duration: 120)
        #expect(a != b)
    }
}

// MARK: - BatteryMonitor tests

/// Tests `BatteryMonitor` using a `MockBatteryDevice` to avoid UIDevice hardware dependency.
@Suite("BatteryMonitor")
@MainActor
struct BatteryMonitorTests {

    @Test("startSession enables battery monitoring on the device")
    func startSessionEnablesMonitoring() {
        let device = MockBatteryDevice(batteryLevel: 0.8)
        let monitor = BatteryMonitor(device: device)
        monitor.startSession()
        #expect(device.isBatteryMonitoringEnabled == true)
    }

    @Test("endSession returns a BatteryReport with correct start and end levels")
    func endSessionReturnsBatteryReport() {
        let device = MockBatteryDevice(batteryLevel: 0.9)
        let monitor = BatteryMonitor(device: device)
        monitor.startSession()
        device.batteryLevel = 0.8   // Simulate drain during session
        let report = monitor.endSession()
        #expect(report != nil)
        #expect(report?.startLevel == 0.9)
        #expect(report?.endLevel == 0.8)
    }

    @Test("endSession without startSession returns nil")
    func endSessionWithoutStartReturnsNil() {
        let device = MockBatteryDevice(batteryLevel: 0.9)
        let monitor = BatteryMonitor(device: device)
        let report = monitor.endSession()
        #expect(report == nil)
    }

    @Test("endSession disables battery monitoring")
    func endSessionDisablesMonitoring() {
        let device = MockBatteryDevice(batteryLevel: 0.9)
        let monitor = BatteryMonitor(device: device)
        monitor.startSession()
        monitor.endSession()
        #expect(device.isBatteryMonitoringEnabled == false)
    }

    @Test("calling endSession twice returns nil on the second call")
    func secondEndSessionReturnsNil() {
        let device = MockBatteryDevice(batteryLevel: 0.8)
        let monitor = BatteryMonitor(device: device)
        monitor.startSession()
        monitor.endSession()
        let second = monitor.endSession()
        #expect(second == nil)
    }
}

// MARK: - Mock

/// `@MainActor`-isolated mock that satisfies the `BatteryDevice` protocol for unit tests.
@MainActor
final class MockBatteryDevice: BatteryDevice {
    var batteryLevel: Float
    var isBatteryMonitoringEnabled: Bool = false

    init(batteryLevel: Float = 0.8) {
        self.batteryLevel = batteryLevel
    }
}
