import Foundation
import Testing
@testable import PicPal

// MARK: - MotionManagerTests

/// Tests for `MotionManager` that don't require live CoreMotion hardware.
///
/// Logic tests (smoothing, settle) live in `MotionProcessorTests`. These tests
/// focus on the observable API contract: initialisation, delegate lifecycle,
/// data-source forwarding, and start/stop routing.
struct MotionManagerTests {

    // MARK: - Initialisation

    @Test func initialDelegateIsNil() {
        let source = MockMotionDataSource()
        let manager = MotionManager(dataSource: source)
        #expect(manager.delegate == nil)
    }

    @Test func isDeviceMotionAvailableForwardedFromDataSource() {
        let source = MockMotionDataSource(isAvailable: false)
        let manager = MotionManager(dataSource: source)
        #expect(!manager.isDeviceMotionAvailable)

        let source2 = MockMotionDataSource(isAvailable: true)
        let manager2 = MotionManager(dataSource: source2)
        #expect(manager2.isDeviceMotionAvailable)
    }

    // MARK: - Delegate lifecycle

    @Test func delegateCanBeAssignedAndRead() {
        let source = MockMotionDataSource()
        let manager = MotionManager(dataSource: source)
        let spy = MotionDelegateSpy()
        manager.delegate = spy
        #expect(manager.delegate != nil)
    }

    @Test func delegateIsHeldWeakly() {
        let source = MockMotionDataSource()
        let manager = MotionManager(dataSource: source)
        var spy: MotionDelegateSpy? = MotionDelegateSpy()
        manager.delegate = spy
        spy = nil
        #expect(manager.delegate == nil)
    }

    // MARK: - Start / stop routing

    @Test func startInvokesDataSourceWhenAvailable() {
        let source = MockMotionDataSource(isAvailable: true)
        let manager = MotionManager(dataSource: source)
        manager.start()
        #expect(source.startCallCount == 1)
    }

    @Test func startDoesNotInvokeDataSourceWhenUnavailable() {
        let source = MockMotionDataSource(isAvailable: false)
        let manager = MotionManager(dataSource: source)
        manager.start()
        #expect(source.startCallCount == 0)
    }

    @Test func stopInvokesDataSource() {
        let source = MockMotionDataSource(isAvailable: true)
        let manager = MotionManager(dataSource: source)
        manager.start()
        manager.stop()
        #expect(source.stopCallCount == 1)
    }

    // MARK: - Delegate callback delivery

    @Test func readingIsDeliveredToDelegateAfterFeed() async {
        let source = MockMotionDataSource(isAvailable: true)
        let manager = MotionManager(dataSource: source)
        let spy = MotionDelegateSpy()
        manager.delegate = spy
        manager.start()

        let (stream, continuation) = AsyncStream<MotionReading>.makeStream()
        spy.onReading = { continuation.yield($0) }

        source.feed(MotionSample(
            roll: 0.1, pitch: 0.2,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
            timestamp: 0.0
        ))

        var it = stream.makeAsyncIterator()
        let received = await it.next()
        #expect(received != nil)
        // First reading passes raw roll through (no smoothing history yet)
        #expect(received?.roll == 0.1)
    }

    @Test func settleEventIsDeliveredAfterWindow() async {
        let source = MockMotionDataSource(isAvailable: true)
        let manager = MotionManager(
            dataSource: source,
            settleThreshold: 0.05,
            settleWindow: 0.35
        )
        let spy = MotionDelegateSpy()
        manager.delegate = spy
        manager.start()

        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        spy.onSettle = { continuation.yield($0) }

        // Feed a still sample at t=0 (clock starts)
        source.feed(MotionSample(
            roll: 0, pitch: 0,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
            timestamp: 0.0
        ))
        // Feed a still sample 0.35 s later — should trigger isSettled = true
        source.feed(MotionSample(
            roll: 0, pitch: 0,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
            timestamp: 0.35
        ))

        var it = stream.makeAsyncIterator()
        let settled = await it.next()
        #expect(settled == true)
    }
}

// MARK: - Test helpers

/// Controllable `MotionDataSource` that feeds synthetic `MotionSample` values directly.
///
/// `startUpdates` captures the handler; `feed(_:)` invokes it synchronously so
/// the test thread can verify results without threading concerns.
final class MockMotionDataSource: MotionDataSource, @unchecked Sendable {
    let isDeviceMotionAvailable: Bool
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var handler: (@Sendable (MotionSample?, Error?) -> Void)?

    init(isAvailable: Bool = true) {
        self.isDeviceMotionAvailable = isAvailable
    }

    func startUpdates(
        to queue: OperationQueue,
        updateInterval: TimeInterval,
        handler: @escaping @Sendable (MotionSample?, Error?) -> Void
    ) {
        startCallCount += 1
        self.handler = handler
    }

    func stopUpdates() {
        stopCallCount += 1
        handler = nil
    }

    /// Synchronously invoke the registered handler with a synthetic sample.
    func feed(_ sample: MotionSample) {
        handler?(sample, nil)
    }
}

/// Minimal `MotionDelegate` spy for unit tests.
///
/// Marked `@unchecked Sendable` because it is only used in single-threaded test
/// scenarios. Properties are `nonisolated(unsafe)` to satisfy `nonisolated` protocol
/// conformance while allowing mutation.
final class MotionDelegateSpy: MotionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onReading: ((MotionReading) -> Void)? = nil
    nonisolated(unsafe) var onSettle: ((Bool) -> Void)? = nil
    nonisolated(unsafe) private(set) var readings: [MotionReading] = []
    nonisolated(unsafe) private(set) var settleEvents: [Bool] = []

    nonisolated func motionManager(_ manager: MotionManager, didUpdate reading: MotionReading) {
        readings.append(reading)
        onReading?(reading)
    }

    nonisolated func motionManager(_ manager: MotionManager, didChangeSettled isSettled: Bool) {
        settleEvents.append(isSettled)
        onSettle?(isSettled)
    }
}
