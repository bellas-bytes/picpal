import Testing
import Foundation
@testable import PicPal

@Suite("ThermalMonitor")
struct ThermalMonitorTests {

    // MARK: - stateName helper

    @Test("stateName: nominal maps to 'nominal'")
    func stateNameNominal() {
        #expect(ThermalMonitor.stateName(for: .nominal) == "nominal")
    }

    @Test("stateName: fair maps to 'fair'")
    func stateNameFair() {
        #expect(ThermalMonitor.stateName(for: .fair) == "fair")
    }

    @Test("stateName: serious maps to 'serious'")
    func stateNameSerious() {
        #expect(ThermalMonitor.stateName(for: .serious) == "serious")
    }

    @Test("stateName: critical maps to 'critical'")
    func stateNameCritical() {
        #expect(ThermalMonitor.stateName(for: .critical) == "critical")
    }

    // MARK: - Notification-driven delegate delivery

    @Test("delegate receives an event when a thermal notification is posted")
    func delegateCalledOnSyntheticNotification() async throws {
        let center = NotificationCenter()
        let spy = ThermalMonitorDelegateSpy()
        let monitor = ThermalMonitor(delegate: spy, notificationCenter: center)
        monitor.start()

        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        // NotificationCenter posts synchronously, so the callback fires immediately.
        #expect(spy.receivedEvents.count == 1)
    }

    @Test("delegate receives state as nominal on simulator")
    func delegateReceivesNominalOnSimulator() async throws {
        let center = NotificationCenter()
        let spy = ThermalMonitorDelegateSpy()
        let monitor = ThermalMonitor(delegate: spy, notificationCenter: center)
        monitor.start()

        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        // On the simulator ProcessInfo.thermalState is always .nominal
        #expect(spy.receivedEvents.first?.state == .nominal)
    }

    @Test("delegate is not called after stop()")
    func delegateNotCalledAfterStop() {
        let center = NotificationCenter()
        let spy = ThermalMonitorDelegateSpy()
        let monitor = ThermalMonitor(delegate: spy, notificationCenter: center)
        monitor.start()
        monitor.stop()

        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        #expect(spy.receivedEvents.isEmpty)
    }

    @Test("multiple notifications produce multiple events")
    func multipleNotificationsProduceMultipleEvents() {
        let center = NotificationCenter()
        let spy = ThermalMonitorDelegateSpy()
        let monitor = ThermalMonitor(delegate: spy, notificationCenter: center)
        monitor.start()

        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        #expect(spy.receivedEvents.count == 2)
    }

    @Test("each event has a non-epoch timestamp")
    func eventTimestampIsRecent() {
        let center = NotificationCenter()
        let spy = ThermalMonitorDelegateSpy()
        let monitor = ThermalMonitor(delegate: spy, notificationCenter: center)
        let before = Date()
        monitor.start()
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        let after = Date()

        guard let event = spy.receivedEvents.first else {
            Issue.record("No event received")
            return
        }
        #expect(event.timestamp >= before)
        #expect(event.timestamp <= after)
    }

    // MARK: - Delegate lifetime

    @Test("nil delegate does not crash when notification is received")
    func nilDelegateDoesNotCrash() {
        let center = NotificationCenter()
        let monitor = ThermalMonitor(delegate: nil, notificationCenter: center)
        monitor.start()
        // Should not crash
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }
}

// MARK: - Test helper

/// Minimal `ThermalMonitorDelegate` spy for unit tests.
final class ThermalMonitorDelegateSpy: ThermalMonitorDelegate, @unchecked Sendable {
    nonisolated(unsafe) private(set) var receivedEvents: [ThermalEvent] = []

    func thermalMonitor(_ monitor: ThermalMonitor, didObserve event: ThermalEvent) {
        receivedEvents.append(event)
    }
}
