import Foundation
import Testing
@testable import PicPal

// MARK: - TiltProcessorTests

/// Tests for the pure `TiltProcessor` angle-conversion and hysteresis logic.
///
/// No device hardware or threading is required — all scenarios use synthetic
/// `MotionReading` values computed inline.
/// Boundary tests use explicit precision settings; the default coaching tests
/// below exercise the more forgiving user-facing behavior through CueEvaluator.
struct TiltProcessorTests {

    // MARK: - Helpers

    private static let radiansPerDegree: Double = .pi / 180.0

    /// A `MotionReading` with the given roll in degrees (converted to radians internally).
    private func reading(rollDegrees: Double, timestamp: TimeInterval = 0) -> MotionReading {
        MotionReading(
            roll: rollDegrees * Self.radiansPerDegree,
            pitch: 0,
            timestamp: timestamp
        )
    }

    // MARK: - Dead-zone: within threshold

    @Test("Angle within dead-zone reports level when previously level")
    func withinDeadZoneIsLevel() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        let signal = processor.process(reading: reading(rollDegrees: 1.0), wasLevel: true)
        #expect(signal.isLevel)
    }

    @Test("Angle within dead-zone reports level when previously tilted")
    func withinDeadZoneIsLevelWhenPreviouslyTilted() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // 0.5° is below deadZone (2.0) − hysteresis (0.5) = 1.5°, so level regardless
        let signal = processor.process(reading: reading(rollDegrees: 0.5), wasLevel: false)
        #expect(signal.isLevel)
    }

    // MARK: - Dead-zone: outside threshold

    @Test("Angle outside dead-zone reports tilted when previously tilted")
    func outsideDeadZoneIsTilted() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // 3.0° is clearly outside dead-zone (2.0°) + hysteresis (0.5°) = 2.5°
        let signal = processor.process(reading: reading(rollDegrees: 3.0), wasLevel: false)
        #expect(!signal.isLevel)
    }

    @Test("Angle outside dead-zone + hysteresis reports tilted even when previously level")
    func outsideUpperHysteresisThresholdIsTilted() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // 2.6° > deadZone (2.0) + hysteresis (0.5) = 2.5° → tilted
        let signal = processor.process(reading: reading(rollDegrees: 2.6), wasLevel: true)
        #expect(!signal.isLevel)
    }

    // MARK: - Hysteresis: level side boundary

    @Test("Angle at dead-zone boundary stays level when previously level")
    func hysteresisAtDeadZoneBoundaryFromLevelSide() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // Exactly at deadZone = 2.0°; wasLevel = true → upper threshold = 2.5° → still level
        let signal = processor.process(reading: reading(rollDegrees: 2.0), wasLevel: true)
        #expect(signal.isLevel)
    }

    @Test("Angle at upper hysteresis threshold stays level when previously level")
    func hysteresisAtUpperThresholdFromLevelSide() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // Exactly at deadZone + hysteresis = 2.5°; boundary is inclusive → still level
        let signal = processor.process(reading: reading(rollDegrees: 2.5), wasLevel: true)
        #expect(signal.isLevel)
    }

    // MARK: - Hysteresis: tilted side boundary

    @Test("Angle at dead-zone boundary stays tilted when previously tilted")
    func hysteresisAtDeadZoneBoundaryFromTiltedSide() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // Exactly at deadZone = 2.0°; wasLevel = false → lower threshold = 1.5° → still tilted
        let signal = processor.process(reading: reading(rollDegrees: 2.0), wasLevel: false)
        #expect(!signal.isLevel)
    }

    @Test("Angle at lower hysteresis threshold stays tilted when previously tilted")
    func hysteresisAtLowerThresholdFromTiltedSide() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // Exactly at deadZone − hysteresis = 1.5°; lower threshold is exclusive → still tilted
        let signal = processor.process(reading: reading(rollDegrees: 1.5), wasLevel: false)
        #expect(!signal.isLevel)
    }

    // MARK: - Angle sign convention

    @Test("Positive roll produces positive angleDegrees")
    func positiveRollProducesPositiveAngle() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        let signal = processor.process(reading: reading(rollDegrees: 5.0), wasLevel: false)
        #expect(signal.angleDegrees > 0)
    }

    @Test("Negative roll produces negative angleDegrees")
    func negativeRollProducesNegativeAngle() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        let signal = processor.process(reading: reading(rollDegrees: -5.0), wasLevel: false)
        #expect(signal.angleDegrees < 0)
    }

    // MARK: - Angle conversion accuracy

    @Test("Known radian value converts to expected degrees within floating-point tolerance")
    func angleConversionAccuracy() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        // π/6 radians = 30°
        let piOver6 = Double.pi / 6.0
        let reading = MotionReading(roll: piOver6, pitch: 0, timestamp: 0)
        let signal = processor.process(reading: reading, wasLevel: false)
        let tolerance = 1e-10
        #expect(abs(signal.angleDegrees - 30.0) < tolerance)
    }

    @Test("Zero roll produces zero angleDegrees")
    func zeroRollProducesZeroAngle() {
        let processor = TiltProcessor(deadZoneDegrees: 2.0, hysteresisDegrees: 0.5)
        let signal = processor.process(reading: reading(rollDegrees: 0.0), wasLevel: true)
        #expect(signal.angleDegrees == 0.0)
        #expect(signal.isLevel)
    }

    // MARK: - Custom configuration

    @Test("Custom dead-zone and hysteresis are respected")
    func customDeadZoneAndHysteresis() {
        let processor = TiltProcessor(deadZoneDegrees: 5.0, hysteresisDegrees: 1.0)
        // Upper threshold = 5.0 + 1.0 = 6.0°; 5.5° should still be level from level side
        let stillLevel = processor.process(reading: reading(rollDegrees: 5.5), wasLevel: true)
        #expect(stillLevel.isLevel)

        // Lower threshold = 5.0 − 1.0 = 4.0°; 4.5° should still be tilted from tilted side
        let stillTilted = processor.process(reading: reading(rollDegrees: 4.5), wasLevel: false)
        #expect(!stillTilted.isLevel)
    }

    @Test("Small correctable tilts do not produce corrective coaching", arguments: [-5.5, -3.0, 3.0, 5.5])
    func smallTiltsStayQuiet(degrees: Double) {
        let signal = TiltProcessor().process(reading: reading(rollDegrees: degrees), wasLevel: true)
        let frame = SignalFrame(timestamp: 0, tilt: signal)
        #expect(CueEvaluator().evaluate(frame: frame) == nil)
    }

    @Test("Obvious tilts still produce a correction", arguments: [-7.0, 7.0])
    func obviousTiltsAreCoached(degrees: Double) {
        let signal = TiltProcessor().process(reading: reading(rollDegrees: degrees), wasLevel: true)
        let cue = CueEvaluator().evaluate(frame: SignalFrame(timestamp: 0, tilt: signal))
        #expect(cue?.text == (degrees > 0 ? CueText.tiltLeft : CueText.tiltRight))
    }

    @Test("A corrected tilt settles without requiring perfect alignment", arguments: [-3.5, 3.5])
    func correctedTiltSettlesEarly(degrees: Double) {
        let signal = TiltProcessor().process(reading: reading(rollDegrees: degrees), wasLevel: false)
        #expect(CueEvaluator().evaluate(frame: SignalFrame(timestamp: 0, tilt: signal)) == nil)
    }

    @Test("Small angle fluctuations do not repeatedly restart tilt coaching")
    func defaultHysteresisAvoidsNagging() {
        let processor = TiltProcessor()
        var wasLevel = true
        let angles = [5.5, 6.5, 5.5, 4.5, 3.5, 4.5, 5.5]
        let expected = [true, false, false, false, true, true, true]
        for (angle, isLevel) in zip(angles, expected) {
            let signal = processor.process(reading: reading(rollDegrees: angle), wasLevel: wasLevel)
            #expect(signal.isLevel == isLevel)
            wasLevel = signal.isLevel
        }
    }
}
