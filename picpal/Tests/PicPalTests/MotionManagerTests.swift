import Foundation
import CoreMotion
import Testing
@testable import PicPal

// MARK: - MotionManagerTests

/// Tests for `MotionManager` that don't require live CoreMotion hardware.
///
/// Logic tests (smoothing, settle) live in `MotionProcessorTests`. These tests
/// focus on the observable API contract: initialisation, delegate lifecycle,
/// data-source forwarding, and start/stop routing.
struct MotionManagerTests {

    @Test("Portrait horizon follows gravity instead of Euler roll", arguments: [-15.0, 0.0, 15.0])
    func portraitHorizonFollowsGravity(degrees: Double) {
        let angle = degrees * .pi / 180
        let motion = PortraitMotionFixture(gravity: CMAcceleration(x: sin(angle), y: -cos(angle), z: 0))
        let sample = CoreMotionDataSource.makeSample(from: motion)
        let signal = TiltProcessor().process(
            reading: MotionReading(roll: sample.roll, pitch: sample.pitch, timestamp: sample.timestamp),
            wasLevel: true
        )
        #expect(abs(signal.angleDegrees - degrees) < 0.001)
        let cue = CueEvaluator().evaluate(frame: SignalFrame(timestamp: 0, tilt: signal))
        if degrees == 0 {
            #expect(cue == nil)
        } else {
            #expect(cue?.text == (degrees > 0 ? CueText.tiltLeft : CueText.tiltRight))
        }
    }

    @Test("A nearly flat phone does not get an arbitrary horizon correction")
    func flatPhoneDoesNotInventTilt() {
        let motion = PortraitMotionFixture(gravity: CMAcceleration(x: 0.001, y: -0.001, z: -0.999999))
        let sample = CoreMotionDataSource.makeSample(from: motion)
        let signal = TiltProcessor().process(
            reading: MotionReading(roll: sample.roll, pitch: sample.pitch, timestamp: sample.timestamp),
            wasLevel: false
        )
        #expect(signal.isLevel)
    }

    @Test("Flat gravity remains neutral in either landscape orientation", arguments: [CaptureOrientation.landscapeLeft, .landscapeRight])
    func flatLandscapeRemainsNeutral(orientation: CaptureOrientation) async {
        let source = MockMotionDataSource()
        let manager = MotionManager(dataSource: source, smoothingFactor: 1)
        let spy = MotionDelegateSpy()
        let (stream, continuation) = AsyncStream<MotionReading>.makeStream()
        spy.onReading = { continuation.yield($0) }
        manager.delegate = spy
        manager.setOrientation(orientation)
        manager.start()
        defer { manager.stop(); continuation.finish() }
        let motion = PortraitMotionFixture(gravity: CMAcceleration(x: 0.001, y: -0.001, z: -0.999999))
        source.feed(CoreMotionDataSource.makeSample(from: motion))
        var iterator = stream.makeAsyncIterator()
        let reading = await iterator.next()
        #expect(reading?.roll == 0)
    }

    @Test("Physical rotation is delivered independently of the current capture orientation")
    func physicalRotationUsesRawGravityAndReachesCameraSubscriber() async {
        let source = MockMotionDataSource()
        let manager = MotionManager(dataSource: source)
        manager.setOrientation(.landscapeRight)
        let (stream, continuation) = AsyncStream<CaptureOrientation>.makeStream()
        let token = NotificationCenter.default.addObserver(forName: MotionManager.physicalOrientationDidChange,
                                                           object: manager, queue: .main) { notification in
            if let orientation = notification.userInfo?["orientation"] as? CaptureOrientation {
                continuation.yield(orientation)
            }
        }
        defer { manager.stop(); NotificationCenter.default.removeObserver(token); continuation.finish() }
        manager.start()
        for timestamp in [0.0, 0.3] {
            source.feed(MotionSample(roll: -.pi / 2, pitch: 0, rotationRateX: 0, rotationRateY: 0,
                                     rotationRateZ: 0, timestamp: timestamp))
        }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == .landscapeLeft)
    }

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

/// Controls the sensor boundary, leaving sample conversion and cue evaluation real.
private final class PortraitMotionFixture: CMDeviceMotion {
    private let gravityValue: CMAcceleration
    private let attitudeValue = PortraitAttitudeFixture()

    init(gravity: CMAcceleration) {
        gravityValue = gravity
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("Not used by sensor fixtures") }

    override var gravity: CMAcceleration { gravityValue }
    override var attitude: CMAttitude { attitudeValue }
    override var rotationRate: CMRotationRate { CMRotationRate(x: 0, y: 0, z: 0) }
    override var timestamp: TimeInterval { 1 }
}

private final class PortraitAttitudeFixture: CMAttitude {
    override var roll: Double { .pi / 2 }
    override var pitch: Double { .pi / 2 }
}

struct PhysicalCameraOrientationTests {
    private func sample(_ roll: Double, _ timestamp: TimeInterval, valid: Bool = true) -> MotionSample {
        MotionSample(roll: roll, pitch: 0, rotationRateX: 0, rotationRateY: 0,
                     rotationRateZ: 0, timestamp: timestamp, isHorizonValid: valid)
    }

    @Test func bothLandscapeDirectionsAndPortraitRequireStableGravity() {
        var tracker = PhysicalCameraOrientationTracker()
        #expect(tracker.update(sample(-.pi / 2, 0)) == nil)
        #expect(tracker.update(sample(-.pi / 2, 0.3)) == .landscapeLeft)
        #expect(tracker.update(sample(-.pi / 2, 0.6)) == nil)
        #expect(tracker.update(sample(.pi / 2, 1)) == nil)
        #expect(tracker.update(sample(.pi / 2, 1.3)) == .landscapeRight)
        #expect(tracker.update(sample(0, 2)) == nil)
        #expect(tracker.update(sample(0, 2.3)) == .portrait)
    }

    @Test func flatDiagonalUpsideDownAndNonfiniteReadingsCannotRotateCamera() {
        var tracker = PhysicalCameraOrientationTracker()
        for angle in [Double.nan, .infinity, .pi / 4, .pi] {
            #expect(tracker.update(sample(angle, 0)) == nil)
            #expect(tracker.update(sample(angle, 1)) == nil)
        }
        #expect(tracker.update(sample(-.pi / 2, 2)) == nil)
        #expect(tracker.update(sample(-.pi / 2, 2.3, valid: false)) == nil)
        #expect(tracker.update(sample(-.pi / 2, 3)) == nil)
        #expect(tracker.update(sample(-.pi / 2, 3.3)) == .landscapeLeft)
    }
}
