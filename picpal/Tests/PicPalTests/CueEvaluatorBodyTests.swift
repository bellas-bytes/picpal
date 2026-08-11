import Foundation
import Testing
@testable import PicPal

// MARK: - CueEvaluatorBodyTests

/// Tests for the M2-6 body signal evaluation blocks in `CueEvaluator`.
///
/// Covers the two new evaluation points:
/// - Block 0.5 — lens obstruction (`.obstruction` priority, before stability check)
/// - Block 4.5 — body framing (`.body` priority, after composition check)
struct CueEvaluatorBodyTests {

    // MARK: - Helpers

    private func bodyFrame(hint: BodyHint, confidence: Float = 0.9) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            body: BodySignal(hint: hint, confidence: confidence, dominantRect: nil)
        )
    }

    private func tiltFrame(degrees: Double = 5.0) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: degrees, isLevel: false)
        )
    }

    private func tiltFrameWithBody(hint: BodyHint) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 5.0, isLevel: false),
            body: BodySignal(hint: hint, confidence: 0.9, dominantRect: nil)
        )
    }

    // MARK: - Block 0.5: Lens obstruction

    @Test("lensObstructed body signal → Cue(priority: .obstruction)")
    func lensObstructedYieldsObstructionCue() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: bodyFrame(hint: .lensObstructed))
        #expect(cue?.text == CueText.lensObstructed)
        #expect(cue?.priority == .obstruction)
        #expect(cue?.sourceTier == .tier05)
    }

    @Test("lensObstructed + active tilt → lensObstructed wins (block 0.5 before tilt)")
    func lensObstructedBeatsActiveTilt() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: tiltFrameWithBody(hint: .lensObstructed))
        // Tilt is checked at block 1, but lensObstructed is at 0.5 — it goes first.
        #expect(cue?.text == CueText.lensObstructed)
        #expect(cue?.priority == .obstruction)
    }

    // MARK: - Block 4.5: Body framing cues

    @Test("awkwardCrop alone → Cue(priority: .body)")
    func awkwardCropYieldsBodyCue() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: bodyFrame(hint: .awkwardCrop))
        #expect(cue?.text == CueText.awkwardCrop)
        #expect(cue?.priority == .body)
        #expect(cue?.sourceTier == .tier05)
    }

    @Test("gazeAway alone → Cue(priority: .body)")
    func gazeAwayYieldsBodyCue() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: bodyFrame(hint: .gazeAway))
        #expect(cue?.text == CueText.gazeAway)
        #expect(cue?.priority == .body)
        #expect(cue?.sourceTier == .tier05)
    }

    @Test("nudgeUpHeadroom alone → Cue(priority: .body)")
    func nudgeUpHeadroomYieldsBodyCue() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: bodyFrame(hint: .nudgeUpHeadroom))
        #expect(cue?.text == CueText.nudgeUpHeadroom)
        #expect(cue?.priority == .body)
        #expect(cue?.sourceTier == .tier05)
    }

    @Test("nudgeDownHeadroom alone → Cue(priority: .body)")
    func nudgeDownHeadroomYieldsBodyCue() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: bodyFrame(hint: .nudgeDownHeadroom))
        #expect(cue?.text == CueText.nudgeDownHeadroom)
        #expect(cue?.priority == .body)
    }

    // MARK: - Silence cases

    @Test("goodBody body signal → nil (silence)")
    func goodBodyYieldsNil() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: bodyFrame(hint: .goodBody))
        #expect(cue == nil)
    }

    @Test("nil body field → no body cue; Tier-0 cues still evaluated")
    func nilBodyFieldDoesNotInterfere() {
        let evaluator = CueEvaluator()
        // A frame with no body signal but a bad tilt should still yield a tilt cue.
        let cue = evaluator.evaluate(frame: tiltFrame())
        #expect(cue?.text == CueText.tiltLeft)
        #expect(cue?.priority == .stability)
    }

    // MARK: - Priority ordering

    @Test("stability (tilt) beats body: tilt + awkwardCrop → tilt wins")
    func stabilityBeatsBodyCue() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            tilt: TiltSignal(angleDegrees: 5.0, isLevel: false),
            body: BodySignal(hint: .awkwardCrop, confidence: 0.9, dominantRect: nil)
        )
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.priority == .stability)
        #expect(cue?.text == CueText.tiltLeft)
    }

    @Test("composition beats body: awkwardCrop + nudgeLeft → nudgeLeft wins")
    func compositionBeatsBodyCue() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            framing: FramingSignal(subjectBox: nil, hint: .nudgeLeft),
            body: BodySignal(hint: .awkwardCrop, confidence: 0.9, dominantRect: nil)
        )
        let cue = evaluator.evaluate(frame: frame)
        // Composition (priority .composition = 2) < body (priority .body = 3)
        // → composition wins
        #expect(cue?.priority == .composition)
        #expect(cue?.text == CueText.nudgeLeft)
    }
}
