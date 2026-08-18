import Foundation
import Testing
@testable import PicPal

// MARK: - CueEvaluator Predictive Integration Tests

/// Tests for `CueEvaluator.evaluate(frame:predictive:)` — verifying that predictive
/// actions gate, replace, or suppress corrective cues without affecting unrelated signals.
@Suite("CueEvaluator predictive integration")
struct CueEvaluatorPredictiveTests {

    // MARK: - Helpers

    private func tiltFrame(degrees: Double, isLevel: Bool = false) -> SignalFrame {
        SignalFrame(timestamp: 0, tilt: TiltSignal(angleDegrees: degrees, isLevel: isLevel))
    }

    private func exposureFrame(level: ExposureLevel) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: level)
        )
    }

    private func blurFrame(isBlurry: Bool) -> SignalFrame {
        SignalFrame(timestamp: 0, blur: BlurSignal(sharpnessScore: isBlurry ? 10 : 300, isBlurry: isBlurry))
    }

    // MARK: - Default (no predictive action) — existing behaviour unchanged

    @Test("no predictive action — tilt bad → standard tiltLeft cue")
    func noPredictive_tiltLeft() {
        let cue = CueEvaluator().evaluate(frame: tiltFrame(degrees: 5.0))
        #expect(cue?.text == CueText.tiltLeft)
    }

    @Test("no predictive action — underexposed → tooDark cue")
    func noPredictive_underexposed() {
        let cue = CueEvaluator().evaluate(frame: exposureFrame(level: .underexposed))
        #expect(cue?.text == CueText.tooDark)
    }

    // MARK: - Tilt: emitPredictiveHint

    @Test("tilt emitPredictiveHint → tiltAlmostLevel with stability priority")
    func tiltPredictiveHint_emitsAlmostLevel() {
        var pa = PredictiveActions()
        pa.tilt = .emitPredictiveHint
        let cue = CueEvaluator().evaluate(frame: tiltFrame(degrees: 3.0), predictive: pa)
        #expect(cue?.text == CueText.tiltAlmostLevel)
        #expect(cue?.priority == .stability)
    }

    // MARK: - Tilt: emitPositiveCue

    @Test("tilt emitPositiveCue → tiltConfirmed with stability priority")
    func tiltPositiveCue_emitsConfirmed() {
        var pa = PredictiveActions()
        pa.tilt = .emitPositiveCue
        let cue = CueEvaluator().evaluate(frame: tiltFrame(degrees: 3.0), predictive: pa)
        #expect(cue?.text == CueText.tiltConfirmed)
        #expect(cue?.priority == .stability)
    }

    // MARK: - Tilt: silent — corrective suppressed; lower-priority cues still fire

    @Test("tilt silent + blur bad → blur cue fires (tilt corrective suppressed)")
    func tiltSilent_blurFires() {
        var pa = PredictiveActions()
        pa.tilt = .silent
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 5.0, isLevel: false),
            blur: BlurSignal(sharpnessScore: 10, isBlurry: true)
        )
        let cue = CueEvaluator().evaluate(frame: frame, predictive: pa)
        #expect(cue?.text == CueText.holdStill)
    }

    @Test("tilt silent + no other signals → nil")
    func tiltSilent_noOtherSignals_nil() {
        var pa = PredictiveActions()
        pa.tilt = .silent
        let cue = CueEvaluator().evaluate(frame: tiltFrame(degrees: 5.0), predictive: pa)
        #expect(cue == nil)
    }

    // MARK: - Blur is never gated by predictive (blur has no predictive path)

    @Test("blur bad — no tilt signal → holdStill, unaffected by any predictive.tilt value")
    func blurUnaffected_byPredictiveTilt() {
        var pa = PredictiveActions()
        pa.tilt = .emitPredictiveHint
        let cue = CueEvaluator().evaluate(frame: blurFrame(isBlurry: true), predictive: pa)
        #expect(cue?.text == CueText.holdStill)
    }

    // MARK: - Exposure: emitPredictiveHint

    @Test("exposure emitPredictiveHint + underexposed → exposureImproving cue")
    func exposureHint_underexposed() {
        var pa = PredictiveActions()
        pa.exposure = .emitPredictiveHint
        let cue = CueEvaluator().evaluate(frame: exposureFrame(level: .underexposed), predictive: pa)
        #expect(cue?.text == CueText.exposureImproving)
        #expect(cue?.priority == .exposure)
    }

    @Test("exposure emitPredictiveHint + overexposed → exposureImproving cue")
    func exposureHint_overexposed() {
        var pa = PredictiveActions()
        pa.exposure = .emitPredictiveHint
        let cue = CueEvaluator().evaluate(frame: exposureFrame(level: .overexposed), predictive: pa)
        #expect(cue?.text == CueText.exposureImproving)
    }

    // MARK: - Exposure: emitPositiveCue

    @Test("exposure emitPositiveCue + underexposed → exposureConfirmed cue")
    func exposurePositiveCue_underexposed() {
        var pa = PredictiveActions()
        pa.exposure = .emitPositiveCue
        let cue = CueEvaluator().evaluate(frame: exposureFrame(level: .underexposed), predictive: pa)
        #expect(cue?.text == CueText.exposureConfirmed)
    }

    @Test("exposure emitPositiveCue + overexposed → exposureConfirmed cue")
    func exposurePositiveCue_overexposed() {
        var pa = PredictiveActions()
        pa.exposure = .emitPositiveCue
        let cue = CueEvaluator().evaluate(frame: exposureFrame(level: .overexposed), predictive: pa)
        #expect(cue?.text == CueText.exposureConfirmed)
    }

    // MARK: - Exposure: silent — lower-priority cues still fire

    @Test("exposure silent + underexposed + framing bad → framing cue fires")
    func exposureSilent_framingFires() {
        var pa = PredictiveActions()
        pa.exposure = .silent
        let frame = SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .underexposed),
            framing: FramingSignal(subjectBox: nil, hint: .nudgeLeft)
        )
        let cue = CueEvaluator().evaluate(frame: frame, predictive: pa)
        #expect(cue?.text == CueText.nudgeLeft)
    }

    @Test("exposure silent + underexposed only → nil")
    func exposureSilent_noOtherSignals_nil() {
        var pa = PredictiveActions()
        pa.exposure = .silent
        let cue = CueEvaluator().evaluate(frame: exposureFrame(level: .underexposed), predictive: pa)
        #expect(cue == nil)
    }

    // MARK: - Obstruction priority: never suppressed

    @Test("obstruction cue not suppressed regardless of predictive.tilt and predictive.exposure")
    func obstructionNeverSuppressed() {
        var pa = PredictiveActions()
        pa.tilt = .silent
        pa.exposure = .silent
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 5.0, isLevel: false),
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .underexposed),
            body: BodySignal(hint: .lensObstructed, confidence: 1.0, dominantRect: nil)
        )
        let cue = CueEvaluator().evaluate(frame: frame, predictive: pa)
        #expect(cue?.text == CueText.lensObstructed)
        #expect(cue?.priority == .obstruction)
    }

    // MARK: - revertToCorrective falls back to standard corrective

    @Test("tilt revertToCorrective + negative angle → tiltRight (standard corrective)")
    func tiltRevert_negativeDegrees_tiltRight() {
        var pa = PredictiveActions()
        pa.tilt = .revertToCorrective
        let cue = CueEvaluator().evaluate(frame: tiltFrame(degrees: -4.0), predictive: pa)
        #expect(cue?.text == CueText.tiltRight)
    }

    @Test("exposure revertToCorrective + overexposed → tooLight (standard corrective)")
    func exposureRevert_overexposed_tooLight() {
        var pa = PredictiveActions()
        pa.exposure = .revertToCorrective
        let cue = CueEvaluator().evaluate(frame: exposureFrame(level: .overexposed), predictive: pa)
        #expect(cue?.text == CueText.tooLight)
    }
}
