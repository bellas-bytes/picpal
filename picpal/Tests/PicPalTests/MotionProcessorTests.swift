import Foundation
import Testing
@testable import PicPal

// MARK: - MotionProcessorTests

/// Tests for the pure `MotionProcessor` settle-detector and low-pass filter logic.
///
/// All scenarios from the brief are covered with synthetic `MotionSample` values;
/// no device hardware or threading is required.
struct MotionProcessorTests {

    // MARK: - Helpers

    /// A sample with no rotation (completely still).
    private func stillSample(at timestamp: TimeInterval, roll: Double = 0.0, pitch: Double = 0.0) -> MotionSample {
        MotionSample(
            roll: roll, pitch: pitch,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
            timestamp: timestamp
        )
    }

    /// A sample with a rotation-rate spike well above the settle threshold.
    private func spikeSample(at timestamp: TimeInterval, magnitude: Double = 0.5) -> MotionSample {
        MotionSample(
            roll: 0, pitch: 0,
            rotationRateX: magnitude, rotationRateY: 0, rotationRateZ: 0,
            timestamp: timestamp
        )
    }

    /// A fresh `MotionProcessor` with the given settle window.
    private func makeProcessor(
        smoothingFactor: Double = 0.3,
        settleThreshold: Double = 0.05,
        settleWindow: TimeInterval = 0.35
    ) -> MotionProcessor {
        MotionProcessor(
            smoothingFactor: smoothingFactor,
            settleThreshold: settleThreshold,
            settleWindow: settleWindow
        )
    }

    // MARK: - Settle: steady input

    @Test func steadyInputSettlesAfterWindow() {
        var p = makeProcessor()

        // t=0: first reading — clock starts here, elapsed = 0, not yet settled
        let (_, c0) = p.process(sample: stillSample(at: 0.0))
        #expect(c0 == nil)
        #expect(!p.isSettled)

        // t=0.34: just under the 0.35 s window
        let (_, c1) = p.process(sample: stillSample(at: 0.34))
        #expect(c1 == nil)
        #expect(!p.isSettled)

        // t=0.35: exactly at the window boundary — should now settle
        let (_, c2) = p.process(sample: stillSample(at: 0.35))
        #expect(c2 == true)
        #expect(p.isSettled)

        // t=0.50: already settled — no repeat event
        let (_, c3) = p.process(sample: stillSample(at: 0.50))
        #expect(c3 == nil)
        #expect(p.isSettled)
    }

    // MARK: - Settle: spike resets the timer

    @Test func spikeAboveThresholdResetsTimer() {
        var p = makeProcessor()

        // Settle first
        _ = p.process(sample: stillSample(at: 0.0))
        let (_, settle) = p.process(sample: stillSample(at: 0.35))
        #expect(settle == true)
        #expect(p.isSettled)

        // Spike at t=0.50 — should immediately unsettle
        let (_, unsettle) = p.process(sample: spikeSample(at: 0.50))
        #expect(unsettle == false)
        #expect(!p.isSettled)

        // t=0.84: 0.34 s after spike — not yet settled (< 0.35 s)
        let (_, c1) = p.process(sample: stillSample(at: 0.84))
        #expect(c1 == nil)
        #expect(!p.isSettled)

        // t=0.85: exactly 0.35 s after spike — should settle again
        let (_, c2) = p.process(sample: stillSample(at: 0.85))
        #expect(c2 == true)
        #expect(p.isSettled)
    }

    // MARK: - Debounce: rapid oscillation prevents flapping

    @Test func rapidOscillationNeverSettles() {
        var p = makeProcessor(settleWindow: 0.35)

        // Feed alternating still/spike pairs at 0.10 s intervals.
        // Each spike is within 0.35 s of the next one, so the timer never
        // reaches the full settle window — the device never declares settled.
        for i in 0..<15 {
            let t = Double(i) * 0.10
            _ = p.process(sample: stillSample(at: t))
            _ = p.process(sample: spikeSample(at: t + 0.05))
        }

        #expect(!p.isSettled)
    }

    @Test func settleChangesAtMostOncePerTransition() {
        var p = makeProcessor()
        var settleEvents: [Bool] = []

        // Settle
        for t in stride(from: 0.0, through: 0.40, by: 0.05) {
            let (_, change) = p.process(sample: stillSample(at: t))
            if let c = change { settleEvents.append(c) }
        }
        // Exactly one true event
        #expect(settleEvents == [true])

        // Spike — one false event
        let (_, c) = p.process(sample: spikeSample(at: 0.50))
        #expect(c == false)
        settleEvents.append(c!)

        // Another spike — no second false event
        let (_, c2) = p.process(sample: spikeSample(at: 0.55))
        #expect(c2 == nil)
    }

    // MARK: - Smoothing: smoothingFactor = 1.0 passes raw values through

    @Test func smoothingFactorOnePassesRawValues() {
        var p = makeProcessor(smoothingFactor: 1.0)

        let (r1, _) = p.process(sample: stillSample(at: 0.0, roll: 0.5, pitch: 0.3))
        #expect(r1.roll  == 0.5)
        #expect(r1.pitch == 0.3)

        // Second reading with α=1.0: smoothed = 1.0 * raw + 0 * prev = raw
        let (r2, _) = p.process(sample: stillSample(at: 0.01, roll: -0.7, pitch: 0.9))
        #expect(r2.roll  == -0.7)
        #expect(r2.pitch == 0.9)
    }

    // MARK: - Smoothing: first reading always passes through regardless of α

    @Test func firstReadingPassesThroughWithNoHistory() {
        var p = makeProcessor(smoothingFactor: 0.3)

        let (r, _) = p.process(sample: stillSample(at: 0.0, roll: 0.7, pitch: -0.4))
        #expect(r.roll  == 0.7)
        #expect(r.pitch == -0.4)
    }

    // MARK: - Smoothing: low-pass formula is applied correctly

    @Test func lowPassFilterAppliesCorrectFormula() {
        var p = makeProcessor(smoothingFactor: 0.3)

        // Seed with initial value (pass-through)
        _ = p.process(sample: stillSample(at: 0.0, roll: 0.0, pitch: 0.0))

        // Second reading: expected = 0.3 * 1.0 + 0.7 * 0.0 = 0.3
        let (r, _) = p.process(sample: stillSample(at: 0.01, roll: 1.0, pitch: 1.0))
        #expect(abs(r.roll  - 0.3) < 1e-10)
        #expect(abs(r.pitch - 0.3) < 1e-10)
    }

    // MARK: - Smoothing: rotation-rate magnitude uses all three axes

    @Test func magnitudeUsesAllThreeRotationAxes() {
        var p = makeProcessor(settleThreshold: 0.05, settleWindow: 0.35)

        // Seed the clock
        _ = p.process(sample: stillSample(at: 0.0))

        // Rotate in Y and Z with a combined magnitude > threshold; X=0
        // sqrt(0² + 0.04² + 0.04²) ≈ 0.0566 > 0.05 — should count as a spike
        let spike = MotionSample(
            roll: 0, pitch: 0,
            rotationRateX: 0.0, rotationRateY: 0.04, rotationRateZ: 0.04,
            timestamp: 0.35
        )
        let (_, change) = p.process(sample: spike)
        // We were about to settle at t=0.35, but the spike resets the timer.
        // The state was still `false` (not yet settled at t=0.35 because the
        // spike fires *at* 0.35), so no false event — but isSettled stays false.
        #expect(!p.isSettled)
        #expect(change == nil)  // state didn't change (was already false)
    }

    // MARK: - MotionReading carries correct timestamp

    @Test func readingTimestampMatchesSampleTimestamp() {
        var p = makeProcessor()
        let (r, _) = p.process(sample: stillSample(at: 1234.56))
        #expect(r.timestamp == 1234.56)
    }
}
