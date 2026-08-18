import Foundation
import os
import Testing
@testable import PicPal

// MARK: - SignalTrendDetector

@Suite("SignalTrendDetector")
struct SignalTrendDetectorTests {
    typealias Signal = SignalTrendDetector.TrackedSignal
    typealias Trend = SignalTrendDetector.Trend

    // MARK: - Basics

    @Test("returns .stable with fewer than 2 samples")
    func stableWithFewerThanTwoSamples() {
        let detector = SignalTrendDetector()
        // zero samples
        #expect(detector.trend(for: .tilt) == .stable)
        // one sample
        detector.record(signal: .tilt, value: 0.5)
        #expect(detector.trend(for: .tilt) == .stable)
    }

    // MARK: - Improving trend

    @Test("returns .improving with decreasing slope exceeding threshold", arguments: [
        Signal.tilt,
        Signal.exposure
    ])
    func improvingWithDecreasingSlope(signal: Signal) {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })
        let startValue: Double = signal == .tilt ? 0.5 : 0.8
        let endValue: Double = signal == .tilt ? 0.41 : 0.71

        clock.advance(by: 0)
        detector.record(signal: signal, value: startValue)
        clock.advance(by: 1.0)
        detector.record(signal: signal, value: endValue)

        #expect(detector.trend(for: signal) == .improving)
    }

    // MARK: - Worsening trend

    @Test("returns .worsening with increasing slope exceeding threshold", arguments: [
        Signal.tilt,
        Signal.exposure
    ])
    func worseningWithIncreasingSlope(signal: Signal) {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })
        let startValue: Double = signal == .tilt ? 0.2 : 0.3
        let endValue: Double = signal == .tilt ? 0.29 : 0.39

        clock.advance(by: 0)
        detector.record(signal: signal, value: startValue)
        clock.advance(by: 1.0)
        detector.record(signal: signal, value: endValue)

        #expect(detector.trend(for: signal) == .worsening)
    }

    // MARK: - Stable trend

    @Test("returns .stable when slope is within threshold")
    func stableWhenSlopeWithinThreshold() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.48)
        // Slope -0.02/sec, within threshold → stable
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }

    @Test("returns .stable when slope is zero")
    func stableWhenZeroSlope() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.5)

        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }

    @Test("concurrent record and trend calls are safe")
    func concurrentRecordAndTrendIsSafe() {
        let detector = SignalTrendDetector()
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            detector.record(signal: .tilt, value: Double(i) * 0.01)
            _ = detector.trend(for: .tilt)
        }
        #expect(true)
    }

    // MARK: - Window trimming

    @Test("trims samples outside window on each record")
    func trimsSamplesOutsideWindow() {
        let clock = MockClock()
        let windowSeconds = 0.5
        let detector = SignalTrendDetector(windowSeconds: windowSeconds, clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.6)

        clock.advance(by: 0.3)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 0.4)
        // Old sample at t=0 outside window (0.4 > 0.5), only t=0.3 remains
        detector.record(signal: Signal.tilt, value: 0.5)
        // Samples at t=0.3 and t=0.7, duration=0.4, slope=0
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }

    // MARK: - Reset

    @Test("reset clears all samples for all signals")
    func resetClearsAllSamples() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: .tilt, value: 0.5)
        clock.advance(by: 1.0)
        detector.record(signal: .tilt, value: 0.41)
        detector.record(signal: .exposure, value: 0.8)
        clock.advance(by: 1.0)
        detector.record(signal: .exposure, value: 0.71)

        // Both signals improving before reset
        #expect(detector.trend(for: .tilt) == .improving)
        #expect(detector.trend(for: .exposure) == .improving)

        // After reset both are stable
        detector.reset()
        #expect(detector.trend(for: .tilt) == .stable)
        #expect(detector.trend(for: .exposure) == .stable)
    }

    // MARK: - Clock injection

    @Test("injectable clock enables deterministic testing")
    func injectableClockDeterministicTesting() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 1.0)

        clock.advance(by: 2.0)
        detector.record(signal: Signal.tilt, value: 0.94)

        // Slope = (0.94 - 1.0) / 2.0 = -0.03
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }

    // MARK: - Multiple samples within window

    @Test("trend computed correctly with multiple samples in window")
    func multipleInWindowComputesTrendCorrectly() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.6)

        clock.advance(by: 0.25)
        detector.record(signal: Signal.tilt, value: 0.55)

        clock.advance(by: 0.5)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 0.75)
        detector.record(signal: Signal.tilt, value: 0.45)
        // Slope ≈ -0.267 < -0.03 → improving
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.improving)
    }

    // MARK: - Independent signals

    @Test("tilt and exposure trends tracked independently")
    func independentSignalTracking() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)
        detector.record(signal: Signal.exposure, value: 0.3)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.41)
        detector.record(signal: Signal.exposure, value: 0.39)
        // Tilt: -0.09/sec → improving; Exposure: +0.09/sec → worsening
        #expect(detector.trend(for: .tilt) == .improving)
        #expect(detector.trend(for: .exposure) == .worsening)
    }

    // MARK: - Custom thresholds

    @Test("respects custom improvement slope threshold")
    func customImprovementSlopeThreshold() {
        let clock = MockClock()
        let customThreshold = 0.1
        let detector = SignalTrendDetector(
            improvementSlopeThreshold: customThreshold,
            clock: { clock.now() }
        )

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.45)
        // Slope -0.05/sec within threshold 0.1 → stable
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }

    @Test("respects custom window seconds")
    func customWindowSeconds() {
        let clock = MockClock()
        let windowSeconds = 0.3
        let detector = SignalTrendDetector(windowSeconds: windowSeconds, clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 0.1)
        detector.record(signal: Signal.tilt, value: 0.45)

        clock.advance(by: 0.25)
        // Sample at t=0 outside 0.3s window (age 0.35 > 0.3), only t=0.1 remains
        detector.record(signal: Signal.tilt, value: 0.4)
        // Duration 0.25s, slope -0.2 < -0.03 → improving
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == .improving)
    }

    // MARK: - Edge cases

    @Test("duration exactly zero returns .stable")
    func durationExactlyZeroReturnsStable() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)
        detector.record(signal: Signal.tilt, value: 0.4)  // Same timestamp

        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }
}

// MARK: - Mock Clock

private final class MockClock: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<TimeInterval>

    init() {
        self.lock = OSAllocatedUnfairLock(initialState: 0)
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { time in
            time += interval
        }
    }

    func now() -> Date {
        let time = lock.withLock { $0 }
        return Date(timeIntervalSinceReferenceDate: time)
    }
}
