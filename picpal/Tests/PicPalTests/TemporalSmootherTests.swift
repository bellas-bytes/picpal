import CoreGraphics
import os
import Testing
@testable import PicPal

// MARK: - Thread-safe test helpers

/// Thread-safe log for `Int?` callback values.
///
/// `@Sendable` closures cannot capture mutable `var` locals under Swift 6
/// strict concurrency. This wrapper satisfies the `Sendable` requirement
/// while keeping the test code readable.
private final class IntCallbackLog: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<[Int?]>

    init() { lock = OSAllocatedUnfairLock(initialState: []) }

    func record(_ value: Int?) { lock.withLock { $0.append(value) } }

    var values: [Int?] { lock.withLock { $0 } }
    var count: Int { lock.withLock { $0.count } }
    var isEmpty: Bool { lock.withLock { $0.isEmpty } }
}

/// Thread-safe log for `SignalFrame` values.
private final class FrameLog: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<[SignalFrame]>

    init() { lock = OSAllocatedUnfairLock(initialState: []) }

    func record(_ frame: SignalFrame) { lock.withLock { $0.append(frame) } }

    var values: [SignalFrame] { lock.withLock { $0 } }
    var count: Int { lock.withLock { $0.count } }
    var last: SignalFrame? { lock.withLock { $0.last } }
}

/// Thread-safe holder for an optional `SignalFrame`.
private final class LastFrameHolder: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<SignalFrame?>

    init() { lock = OSAllocatedUnfairLock(initialState: nil) }

    func set(_ frame: SignalFrame) { lock.withLock { $0 = frame } }

    var value: SignalFrame? { lock.withLock { $0 } }
}

// MARK: - Fixtures

private enum SmootherFixture {
    /// Default window — matches `TemporalSmoother.defaultStableFrameCount`.
    static let defaultWindow: Int = TemporalSmoother<Int>.defaultStableFrameCount
    /// Primary value used in run-stability tests.
    static let valueA: Int = 42
    /// A different value used to break a run.
    static let valueB: Int = 99
}

// MARK: - TemporalSmootherTests

/// Swift Testing suite for `TemporalSmoother<T>` and `SignalFrameAccumulator.update(body:)`.
///
/// All tests drive the smoother synchronously on the test thread; callbacks
/// fire inline because `TemporalSmoother` invokes `onStable` on the calling
/// thread after releasing its lock.
struct TemporalSmootherTests {

    // MARK: - Stable run fires after N frames

    @Test("onStable fires exactly once after stableFrameCount equal frames")
    func stableRunFiresAfterNFrames() {
        let log = IntCallbackLog()
        let smoother = TemporalSmoother<Int>(
            stableFrameCount: SmootherFixture.defaultWindow
        ) { log.record($0) }

        // One fewer than required — no callback yet.
        for _ in 0..<(SmootherFixture.defaultWindow - 1) {
            smoother.update(SmootherFixture.valueA)
        }
        #expect(log.isEmpty)

        // The completing frame — exactly one callback expected.
        smoother.update(SmootherFixture.valueA)
        #expect(log.count == 1)
        #expect(log.values.first == SmootherFixture.valueA)
    }

    // MARK: - Edge-triggered: no re-fire on subsequent equal values

    @Test("onStable does not re-fire after stability is confirmed")
    func edgeTriggeredNoReFire() {
        let log = IntCallbackLog()
        let smoother = TemporalSmoother<Int>(
            stableFrameCount: SmootherFixture.defaultWindow
        ) { log.record($0) }

        // Establish stability.
        for _ in 0..<SmootherFixture.defaultWindow {
            smoother.update(SmootherFixture.valueA)
        }
        let countAfterStable = log.count
        #expect(countAfterStable == 1)

        // More frames with the same value must NOT re-fire.
        for _ in 0..<5 {
            smoother.update(SmootherFixture.valueA)
        }
        #expect(log.count == countAfterStable)
    }

    // MARK: - Run-break on value change fires nil

    @Test("Changing value after stability fires onStable(nil) exactly once")
    func runBreakOnValueChangeFiresNil() {
        let log = IntCallbackLog()
        let smoother = TemporalSmoother<Int>(
            stableFrameCount: SmootherFixture.defaultWindow
        ) { log.record($0) }

        for _ in 0..<SmootherFixture.defaultWindow {
            smoother.update(SmootherFixture.valueA)
        }
        #expect(log.values == [SmootherFixture.valueA])

        smoother.update(SmootherFixture.valueB)
        #expect(log.values == [SmootherFixture.valueA, nil])
    }

    // MARK: - update(nil) fires nil when stable

    @Test("update(nil) fires onStable(nil) when a stable value was previously confirmed")
    func updateNilFiresNilWhenStable() {
        let log = IntCallbackLog()
        let smoother = TemporalSmoother<Int>(
            stableFrameCount: SmootherFixture.defaultWindow
        ) { log.record($0) }

        for _ in 0..<SmootherFixture.defaultWindow { smoother.update(SmootherFixture.valueA) }
        #expect(log.values == [SmootherFixture.valueA])

        smoother.update(nil)
        #expect(log.values == [SmootherFixture.valueA, nil])
    }

    // MARK: - update(nil) is silent when not yet stable

    @Test("update(nil) fires no callback when stability was not confirmed")
    func updateNilSilentWhenNotStable() {
        let log = IntCallbackLog()
        let smoother = TemporalSmoother<Int>(
            stableFrameCount: SmootherFixture.defaultWindow
        ) { log.record($0) }

        smoother.update(SmootherFixture.valueA)
        smoother.update(nil)
        #expect(log.isEmpty)
    }

    // MARK: - reset() clears state

    @Test("reset() clears accumulated state without firing a callback")
    func resetClearsState() {
        let log = IntCallbackLog()
        let smoother = TemporalSmoother<Int>(
            stableFrameCount: SmootherFixture.defaultWindow
        ) { log.record($0) }

        // Partially fill the run.
        for _ in 0..<(SmootherFixture.defaultWindow - 1) {
            smoother.update(SmootherFixture.valueA)
        }
        smoother.reset()
        #expect(log.isEmpty)

        // A full new run after reset must fire normally.
        for _ in 0..<SmootherFixture.defaultWindow {
            smoother.update(SmootherFixture.valueA)
        }
        #expect(log.values == [SmootherFixture.valueA])
    }

    // MARK: - New run after nil

    @Test("A new run can establish stability after a nil-break")
    func newRunAfterNilCanBecomeStable() {
        let log = IntCallbackLog()
        let smoother = TemporalSmoother<Int>(
            stableFrameCount: SmootherFixture.defaultWindow
        ) { log.record($0) }

        for _ in 0..<SmootherFixture.defaultWindow { smoother.update(SmootherFixture.valueA) }
        smoother.update(nil)
        for _ in 0..<SmootherFixture.defaultWindow { smoother.update(SmootherFixture.valueB) }

        #expect(log.values == [SmootherFixture.valueA, nil, SmootherFixture.valueB])
    }

    // MARK: - SignalFrameAccumulator.update(body:)

    @Test("update(body:) merges BodySignal into the accumulated SignalFrame")
    func accumulatorUpdateBodyMergesCorrectly() {
        let frameLog = FrameLog()
        let accumulator = SignalFrameAccumulator(
            clock: { 1.0 }
        ) { frameLog.record($0) }

        let body = BodySignal(
            hint: .nudgeUpHeadroom,
            confidence: 0.85,
            dominantRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        )
        accumulator.update(body: body)

        #expect(frameLog.count == 1)
        #expect(frameLog.last?.body == body)
        // Other signals start nil — accumulator began from .empty.
        #expect(frameLog.last?.tilt == nil)
        #expect(frameLog.last?.blur == nil)
    }

    @Test("update(body:) preserves pre-existing signals in the accumulated frame")
    func accumulatorUpdateBodyPreservesOtherSignals() {
        let holder = LastFrameHolder()
        let accumulator = SignalFrameAccumulator(
            clock: { 2.0 }
        ) { holder.set($0) }

        // First establish a tilt signal.
        let tilt = TiltSignal(angleDegrees: 5.0, isLevel: false)
        accumulator.update(tilt: tilt)

        // Updating body must not erase tilt.
        let body = BodySignal(hint: .goodBody, confidence: 1.0, dominantRect: nil)
        accumulator.update(body: body)

        #expect(holder.value?.body == body)
        #expect(holder.value?.tilt == tilt)
    }

    @Test("SignalFrame.empty has body set to nil")
    func signalFrameEmptyBodyIsNil() {
        #expect(SignalFrame.empty.body == nil)
    }
}
