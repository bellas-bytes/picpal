import Foundation
import os
import Testing
@testable import PicPal

// MARK: - PredictiveCoordinator Tests

@Suite("PredictiveCoordinator")
struct PredictiveCoordinatorTests {

    // MARK: - Helpers

    /// Builds a tilt-only frame with the given angle. isLevel reflects abs(angle) < 3°.
    private func tiltFrame(degrees: Double) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: degrees, isLevel: abs(degrees) < 3.0)
        )
    }

    /// Builds an exposure frame with the given clip fraction and level.
    private func exposureFrame(
        shadow: Double,
        highlight: Double,
        level: ExposureLevel
    ) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(
                shadowClipFraction: shadow,
                highlightClipFraction: highlight,
                level: level
            )
        )
    }

    // MARK: - Test 1: tiltRecordedAndTrendFed

    @Test("tilt signal recorded; improving inputs produce emitPredictiveHint for tilt")
    func tiltRecordedAndTrendFed() {
        let clock = MockCoordClock()
        let detector = SignalTrendDetector(clock: { clock.now() })
        let tiltCoach = PredictiveCoach(clock: { clock.now() })
        let exposureCoach = PredictiveCoach(clock: { clock.now() })
        let coord = PredictiveCoordinator(
            detector: detector,
            tiltCoach: tiltCoach,
            exposureCoach: exposureCoach
        )

        // Seed improving tilt (angle decreasing → slope < -0.03 over 1 s window)
        detector.record(signal: .tilt, value: 10.0)
        clock.advance(by: 1.0)
        detector.record(signal: .tilt, value: 3.5)

        // Coordinator.update() at t=1.0; tilt not level, angle positive → improving trend
        let actions = coord.update(tiltFrame(degrees: 3.5))
        #expect(actions.tilt == .emitPredictiveHint)
    }

    // MARK: - Test 2: exposureRecordedWhenNotOk

    @Test("exposure clipping recorded when level is not .ok, trend reflects improvement")
    func exposureRecordedWhenNotOk() {
        let clock = MockCoordClock()
        let detector = SignalTrendDetector(clock: { clock.now() })
        let tiltCoach = PredictiveCoach(clock: { clock.now() })
        let exposureCoach = PredictiveCoach(clock: { clock.now() })
        let coord = PredictiveCoordinator(
            detector: detector,
            tiltCoach: tiltCoach,
            exposureCoach: exposureCoach
        )

        // Seed improving exposure clipping (highlight fraction decreasing)
        detector.record(signal: .exposure, value: 0.80)
        clock.advance(by: 1.0)
        detector.record(signal: .exposure, value: 0.20)

        // Frame: underexposed (level != .ok), so coordinator records and queries trend
        let frame = exposureFrame(shadow: 0.0, highlight: 0.20, level: .underexposed)
        let actions = coord.update(frame)
        #expect(actions.exposure == .emitPredictiveHint)
    }

    // MARK: - Test 3: exposureNotRecordedWhenOk

    @Test("exposure not recorded when level is .ok — trend stays stable")
    func exposureNotRecordedWhenOk() {
        let clock = MockCoordClock()
        let detector = SignalTrendDetector(clock: { clock.now() })
        let tiltCoach = PredictiveCoach(clock: { clock.now() })
        let exposureCoach = PredictiveCoach(clock: { clock.now() })
        let coord = PredictiveCoordinator(
            detector: detector,
            tiltCoach: tiltCoach,
            exposureCoach: exposureCoach
        )

        // When level is .ok, coordinator must NOT record exposure → trend stays .stable
        let frame = exposureFrame(shadow: 0.0, highlight: 0.05, level: .ok)
        _ = coord.update(frame)

        // No samples recorded for .ok → trend is still .stable
        #expect(detector.trend(for: .exposure) == .stable)
    }

    // MARK: - Test 4: resetClearsCoachState

    @Test("reset clears coach state — next improving frame re-emits predictive hint")
    func resetClearsCoachState() {
        let clock = MockCoordClock()
        let detector = SignalTrendDetector(clock: { clock.now() })
        let tiltCoach = PredictiveCoach(clock: { clock.now() })
        let exposureCoach = PredictiveCoach(clock: { clock.now() })
        let coord = PredictiveCoordinator(
            detector: detector,
            tiltCoach: tiltCoach,
            exposureCoach: exposureCoach
        )

        // Seed improving tilt to trigger emitPredictiveHint
        detector.record(signal: .tilt, value: 10.0)
        clock.advance(by: 1.0)
        detector.record(signal: .tilt, value: 3.5)
        let first = coord.update(tiltFrame(degrees: 3.5))
        #expect(first.tilt == .emitPredictiveHint)

        // Reset clears coach state
        coord.reset()

        // Seed improving samples again (detector was reset too)
        clock.advance(by: 0.1)
        detector.record(signal: .tilt, value: 9.0)
        clock.advance(by: 1.0)
        detector.record(signal: .tilt, value: 4.5)

        // Use 4.5° — still improving, not yet within 3° threshold; coach was reset to idle
        let second = coord.update(tiltFrame(degrees: 4.5))
        #expect(second.tilt == .emitPredictiveHint)
    }

    // MARK: - Test 5: tiltAndExposureActionsIndependent

    @Test("tilt improving + exposure worsening → independent actions per signal")
    func tiltAndExposureActionsIndependent() {
        let clock = MockCoordClock()
        let detector = SignalTrendDetector(clock: { clock.now() })
        let tiltCoach = PredictiveCoach(clock: { clock.now() })
        let exposureCoach = PredictiveCoach(clock: { clock.now() })
        let coord = PredictiveCoordinator(
            detector: detector,
            tiltCoach: tiltCoach,
            exposureCoach: exposureCoach
        )

        // Tilt: improving (decreasing angle)
        detector.record(signal: .tilt, value: 12.0)
        // Exposure: worsening (increasing clipping fraction)
        detector.record(signal: .exposure, value: 0.10)
        clock.advance(by: 1.0)
        detector.record(signal: .tilt, value: 4.0)
        detector.record(signal: .exposure, value: 0.80)

        // Combined frame: tilt not level, exposure underexposed
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 4.0, isLevel: false),
            exposure: ExposureSignal(
                shadowClipFraction: 0.0,
                highlightClipFraction: 0.80,
                level: .underexposed
            )
        )
        let actions = coord.update(frame)

        // Tilt improving → emitPredictiveHint; exposure worsening → revertToCorrective
        #expect(actions.tilt == .emitPredictiveHint)
        #expect(actions.exposure == .revertToCorrective)
    }
}

// MARK: - MockCoordClock

private final class MockCoordClock: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<TimeInterval>

    init(startAt t: TimeInterval = 0) {
        self.lock = OSAllocatedUnfairLock(initialState: t)
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { $0 += interval }
    }

    func now() -> Date {
        Date(timeIntervalSinceReferenceDate: lock.withLock { $0 })
    }
}
