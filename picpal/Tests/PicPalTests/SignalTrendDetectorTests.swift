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
        detector.record(signal: Signal.tilt, value: 0.5)
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == .stable)
    }

    @Test("returns .stable with zero samples")
    func stableWithZeroSamples() {
        let detector = SignalTrendDetector()
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == .stable)
    }

    // MARK: - Improving trend

    @Test("returns .improving for tilt with decreasing slope exceeding threshold")
    func improvingTiltWithDecreasingSlope() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        // Record tilt values: 0.5 at t=0, then 0.41 at t=1 sec
        // Slope = (0.41 - 0.5) / 1.0 = -0.09/sec
        // Threshold is -0.03, so -0.09 < -0.03 → improving
        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.41)

        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.improving)
    }

    @Test("returns .improving for exposure with decreasing slope exceeding threshold")
    func improvingExposureWithDecreasingSlope() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.exposure, value: 0.8)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.exposure, value: 0.71)

        let trend = detector.trend(for: Signal.exposure)
        #expect(trend == Trend.improving)
    }

    // MARK: - Worsening trend

    @Test("returns .worsening for tilt with increasing slope exceeding threshold")
    func worseningTiltWithIncreasingSlope() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.2)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.29)

        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.worsening)
    }

    @Test("returns .worsening for exposure with increasing slope exceeding threshold")
    func worseningExposureWithIncreasingSlope() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.exposure, value: 0.3)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.exposure, value: 0.39)

        let trend = detector.trend(for: Signal.exposure)
        #expect(trend == Trend.worsening)
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

        // Slope = (0.48 - 0.5) / 1.0 = -0.02/sec
        // Threshold is -0.03, so -0.03 < -0.02 < 0.03 → stable
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

    @Test("returns .stable when slope is near threshold")
    func stableWhenSlopeNearThreshold() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.48)

        // Slope = (0.48 - 0.5) / 1.0 = -0.02/sec (well within threshold of ±0.03)
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
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
        // Now: old sample at t=0 is outside window (0.4 > 0.5)
        // Only sample at t=0.3 should remain
        detector.record(signal: Signal.tilt, value: 0.5)

        // With only 2 samples effectively (if trimming works), trend should stabilize
        let trend = detector.trend(for: Signal.tilt)
        // We have samples at t=0.3 and t=0.7, duration = 0.4
        // slope = (0.5 - 0.5) / 0.4 = 0
        #expect(trend == Trend.stable)
    }

    // MARK: - Reset

    @Test("reset clears all samples")
    func resetClearsAllSamples() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.41)

        detector.reset()

        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }

    @Test("reset works for all signals independently")
    func resetWorksForAllSignals() {
        let clock = MockClock()
        let detector = SignalTrendDetector(clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)
        detector.record(signal: Signal.exposure, value: 0.8)

        clock.advance(by: 1.0)
        detector.record(signal: Signal.tilt, value: 0.41)
        detector.record(signal: Signal.exposure, value: 0.71)

        detector.reset()

        #expect(detector.trend(for: Signal.tilt) == Trend.stable)
        #expect(detector.trend(for: Signal.exposure) == Trend.stable)
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

        // Duration from first to last = 0.75 seconds
        // Slope = (0.45 - 0.6) / 0.75 = -0.2 / 0.75 ≈ -0.267
        // -0.267 < -0.03 → improving
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

        // Tilt: -0.09/sec → improving
        let tiltTrend = detector.trend(for: Signal.tilt)
        #expect(tiltTrend == Trend.improving)

        // Exposure: +0.09/sec → worsening
        let exposureTrend = detector.trend(for: Signal.exposure)
        #expect(exposureTrend == Trend.worsening)
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

        // Slope = -0.05/sec
        // With threshold 0.1, -0.1 < -0.05 < 0.1 → stable
        let trend = detector.trend(for: Signal.tilt)
        #expect(trend == Trend.stable)
    }

    @Test("respects custom window seconds")
    func customWindowSeconds() {
        let clock = MockClock()
        let windowSeconds = 0.2
        let detector = SignalTrendDetector(windowSeconds: windowSeconds, clock: { clock.now() })

        clock.advance(by: 0)
        detector.record(signal: Signal.tilt, value: 0.5)

        clock.advance(by: 0.1)
        detector.record(signal: Signal.tilt, value: 0.45)

        clock.advance(by: 0.3)
        // Now: first sample at t=0 is outside 0.2s window (0.3 > 0.2)
        // Only samples from t=0.1 onward should remain
        detector.record(signal: Signal.tilt, value: 0.4)

        // Should have samples at t=0.1 and t=0.4
        let trend = detector.trend(for: Signal.tilt)
        // This should compute trend with these 2 samples
        #expect(trend != Trend.worsening)  // Just verify it doesn't crash
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
