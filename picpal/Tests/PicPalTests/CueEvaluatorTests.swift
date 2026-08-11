import Foundation
import Testing
@testable import PicPal

// MARK: - CueEvaluatorTests

/// Tests for `CueEvaluator` — pure stateless evaluation with no clock or debounce state.
struct CueEvaluatorTests {

    // MARK: - Helpers

    private func tiltFrame(degrees: Double, isLevel: Bool = false) -> SignalFrame {
        SignalFrame(timestamp: 0, tilt: TiltSignal(angleDegrees: degrees, isLevel: isLevel))
    }

    private func blurFrame(isBlurry: Bool) -> SignalFrame {
        SignalFrame(timestamp: 0, blur: BlurSignal(sharpnessScore: isBlurry ? 10 : 300, isBlurry: isBlurry))
    }

    private func exposureFrame(level: ExposureLevel) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: level)
        )
    }

    private func framingFrame(hint: FramingHint) -> SignalFrame {
        SignalFrame(timestamp: 0, framing: FramingSignal(subjectBox: nil, hint: hint))
    }

    // MARK: - Tilt

    @Test("Tilt not level (positive angle) → tiltLeft stability cue")
    func tiltPositiveYieldsTiltLeft() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: tiltFrame(degrees: 5.0))
        #expect(cue?.text == CueText.tiltLeft)
        #expect(cue?.priority == .stability)
        #expect(cue?.sourceTier == .tier0)
    }

    @Test("Tilt not level (negative angle) → tiltRight stability cue")
    func tiltNegativeYieldsTiltRight() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: tiltFrame(degrees: -3.0))
        #expect(cue?.text == CueText.tiltRight)
        #expect(cue?.priority == .stability)
    }

    @Test("Tilt is level → no cue emitted")
    func tiltLevelYieldsNil() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: tiltFrame(degrees: 1.0, isLevel: true))
        #expect(cue == nil)
    }

    // MARK: - Blur

    @Test("Blurry frame → holdStill stability cue")
    func blurryFrameYieldsHoldStill() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: blurFrame(isBlurry: true))
        #expect(cue?.text == CueText.holdStill)
        #expect(cue?.priority == .stability)
    }

    @Test("Sharp frame → no cue emitted")
    func sharpFrameYieldsNil() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: blurFrame(isBlurry: false))
        #expect(cue == nil)
    }

    // MARK: - Tilt + Blur tie-break

    @Test("Both tilt and blur bad → tilt wins (tie-break rule: tilt first in chain)")
    func tiltAndBlurBothBadTiltWins() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 5.0, isLevel: false),
            blur: BlurSignal(sharpnessScore: 10, isBlurry: true)
        )
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.text == CueText.tiltLeft)  // not holdStill
    }

    // MARK: - Exposure

    @Test("Underexposed frame → tooDark exposure cue")
    func underexposedYieldsTooDark() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: exposureFrame(level: .underexposed))
        #expect(cue?.text == CueText.tooDark)
        #expect(cue?.priority == .exposure)
    }

    @Test("Overexposed frame → tooLight exposure cue")
    func overexposedYieldsTooLight() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: exposureFrame(level: .overexposed))
        #expect(cue?.text == CueText.tooLight)
        #expect(cue?.priority == .exposure)
    }

    @Test("OK exposure → no cue emitted")
    func okExposureYieldsNil() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: exposureFrame(level: .ok))
        #expect(cue == nil)
    }

    // MARK: - Framing

    @Test("Framing nudgeLeft hint → nudgeLeft composition cue")
    func framingNudgeLeftYieldsNudgeLeft() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: framingFrame(hint: .nudgeLeft))
        #expect(cue?.text == CueText.nudgeLeft)
        #expect(cue?.priority == .composition)
    }

    @Test("Framing nudgeRight hint → nudgeRight composition cue")
    func framingNudgeRightYieldsNudgeRight() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: framingFrame(hint: .nudgeRight))
        #expect(cue?.text == CueText.nudgeRight)
    }

    @Test("Framing nudgeUp hint → nudgeUp composition cue")
    func framingNudgeUpYieldsNudgeUp() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: framingFrame(hint: .nudgeUp))
        #expect(cue?.text == CueText.nudgeUp)
    }

    @Test("Framing nudgeDown hint → nudgeDown composition cue")
    func framingNudgeDownYieldsNudgeDown() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: framingFrame(hint: .nudgeDown))
        #expect(cue?.text == CueText.nudgeDown)
    }

    @Test("Framing tooCentered hint → tooCentered composition cue")
    func framingTooCenteredYieldsTooCentered() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: framingFrame(hint: .tooCentered))
        #expect(cue?.text == CueText.tooCentered)
    }

    @Test("Framing goodFrame hint → no cue emitted")
    func framingGoodFrameYieldsNil() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: framingFrame(hint: .goodFrame))
        #expect(cue == nil)
    }

    @Test("Framing noSubject hint → no cue emitted")
    func framingNoSubjectYieldsNil() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: framingFrame(hint: .noSubject))
        #expect(cue == nil)
    }

    // MARK: - Good frame (all signals clean)

    @Test("All signals good → nil (silence)")
    func allSignalsGoodYieldsNil() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 0.5, isLevel: true),
            blur: BlurSignal(sharpnessScore: 250, isBlurry: false),
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .ok),
            framing: FramingSignal(subjectBox: nil, hint: .goodFrame)
        )
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue == nil)
    }

    // MARK: - Nil signals in SignalFrame

    @Test("Empty SignalFrame (all signals nil) → no crash, no cue")
    func emptyFrameYieldsNil() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: .empty)
        #expect(cue == nil)
    }

    @Test("SignalFrame with only blur nil → tilt cue still emitted")
    func tiltCueEmittedWhenBlurNil() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 4.0, isLevel: false),
            blur: nil
        )
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.text == CueText.tiltLeft)
    }

    // MARK: - Priority — stability beats composition

    @Test("Stability beats composition: tilt + framing both bad → tilt cue emitted")
    func stabilityBeatsComposition() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 5.0, isLevel: false),
            framing: FramingSignal(subjectBox: nil, hint: .nudgeLeft)
        )
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.priority == .stability)
        #expect(cue?.text == CueText.tiltLeft)
    }

    @Test("Exposure beats composition: exposure bad + framing bad → exposure cue emitted")
    func exposureBeatsComposition() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .overexposed),
            framing: FramingSignal(subjectBox: nil, hint: .nudgeRight)
        )
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.priority == .exposure)
        #expect(cue?.text == CueText.tooLight)
    }

    // MARK: - CuePriority ordering

    @Test("CuePriority: stability < exposure < composition")
    func priorityOrdering() {
        #expect(CuePriority.stability < CuePriority.exposure)
        #expect(CuePriority.exposure < CuePriority.composition)
        #expect(CuePriority.composition < CuePriority.body)
        #expect(CuePriority.body < CuePriority.aesthetic)
    }
}
