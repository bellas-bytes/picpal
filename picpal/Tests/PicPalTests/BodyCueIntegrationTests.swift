import Foundation
import Testing
@testable import PicPal

// MARK: - TestClock (body integration)

/// Reference-type clock that can be advanced in tests without violating Swift 6
/// `@Sendable` capture rules.
private final class BodyTestClock: @unchecked Sendable {
    var now: Date

    init(_ date: Date = Date(timeIntervalSince1970: 0)) {
        now = date
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

// MARK: - BodyCueIntegrationTests

/// End-to-end integration tests for the `BodySignal → CueEngine` path.
///
/// Exercises the stateful `CueEngine.process(frame:)` with synthetic `BodySignal`s.
/// No camera, Vision, MediaPipe, or AVFoundation — all signals are constructed directly.
///
/// Complements the pure-evaluator coverage in `CueEvaluatorBodyTests` by exercising
/// the full pipeline including CueEngine cooldown, repeat-suppression, and priority bypass.
struct BodyCueIntegrationTests {

    // MARK: - Helpers

    /// Returns a `SignalFrame` with the given body signal and all tier-0 signals clean.
    private func makeBodyFrame(_ body: BodySignal) -> SignalFrame {
        SignalFrame(
            timestamp: 1.0,
            tilt: TiltSignal(angleDegrees: 0.0, isLevel: true),
            blur: BlurSignal(sharpnessScore: 100.0, isBlurry: false),
            exposure: ExposureSignal(
                shadowClipFraction: 0.01,
                highlightClipFraction: 0.01,
                level: .ok
            ),
            framing: FramingSignal(subjectBox: nil, hint: .goodFrame),
            body: body
        )
    }

    /// Returns a `SignalFrame` with a nudge-left framing cue and no body signal.
    /// Used to prime the engine with a composition-priority cooldown.
    private func makeCompositionFrame() -> SignalFrame {
        SignalFrame(
            timestamp: 1.0,
            tilt: TiltSignal(angleDegrees: 0.0, isLevel: true),
            blur: BlurSignal(sharpnessScore: 100.0, isBlurry: false),
            exposure: ExposureSignal(
                shadowClipFraction: 0.01,
                highlightClipFraction: 0.01,
                level: .ok
            ),
            framing: FramingSignal(subjectBox: nil, hint: .nudgeLeft),
            body: nil
        )
    }

    // MARK: - Test 1: lensObstructed → stability cue

    @Test("lensObstructed body signal → CueEngine emits stability cue with correct text and tier")
    func lensObstructedEmitsStabilityCue() {
        let engine = CueEngine()
        let body = BodySignal(hint: .lensObstructed, confidence: 0.9, dominantRect: nil)
        let cue = engine.process(frame: makeBodyFrame(body))
        #expect(cue?.text == CueText.lensObstructed)
        #expect(cue?.priority == .stability)
        #expect(cue?.sourceTier == .tier05)
    }

    // MARK: - Test 2: lensObstructed bypasses lower-priority cooldown

    /// Verifies that a `.stability` cue (lensObstructed) bypasses an active cooldown
    /// triggered by a lower-priority `.composition` cue. This exercises the
    /// `candidate.priority < last.priority` guard in `CueEngine.process(frame:)`.
    @Test("lensObstructed (stability) bypasses active composition-priority cooldown")
    func lensObstructedBypassesCompositionCooldown() {
        let clock = BodyTestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 10.0,
            minRepeatIntervalSeconds: 30.0,
            clock: { clock.now }
        )

        // Step (a): prime the engine with a composition cue to start cooldown.
        let cue1 = engine.process(frame: makeCompositionFrame())
        #expect(cue1?.priority == .composition)

        // Step (b): immediately emit a lensObstructed frame — still within cooldown.
        clock.advance(by: 0.1)
        let body = BodySignal(hint: .lensObstructed, confidence: 0.9, dominantRect: nil)
        let cue2 = engine.process(frame: makeBodyFrame(body))

        // Step (c): lensObstructed fires despite the active cooldown —
        // .stability (0) < .composition (2) triggers the priority bypass.
        #expect(cue2?.text == CueText.lensObstructed)
        #expect(cue2?.priority == .stability)
    }

    // MARK: - Test 3: awkwardCrop → body cue

    @Test("awkwardCrop body signal → CueEngine emits body-priority cue")
    func awkwardCropEmitsBodyCue() {
        let engine = CueEngine()
        let body = BodySignal(hint: .awkwardCrop, confidence: 0.9, dominantRect: nil)
        let cue = engine.process(frame: makeBodyFrame(body))
        #expect(cue?.text == CueText.awkwardCrop)
        #expect(cue?.priority == .body)
    }

    // MARK: - Test 4: gazeAway → body cue

    @Test("gazeAway body signal → CueEngine emits body-priority cue")
    func gazeAwayEmitsBodyCue() {
        let engine = CueEngine()
        let body = BodySignal(hint: .gazeAway, confidence: 0.9, dominantRect: nil)
        let cue = engine.process(frame: makeBodyFrame(body))
        #expect(cue?.text == CueText.gazeAway)
        #expect(cue?.priority == .body)
    }

    // MARK: - Test 5: nudgeDownHeadroom → body cue

    @Test("nudgeDownHeadroom body signal → CueEngine emits body-priority cue")
    func nudgeDownHeadroomEmitsBodyCue() {
        let engine = CueEngine()
        let body = BodySignal(hint: .nudgeDownHeadroom, confidence: 0.9, dominantRect: nil)
        let cue = engine.process(frame: makeBodyFrame(body))
        #expect(cue?.text == CueText.nudgeDownHeadroom)
        #expect(cue?.priority == .body)
    }

    // MARK: - Test 6: nudgeUpHeadroom → body cue

    @Test("nudgeUpHeadroom body signal → CueEngine emits body-priority cue")
    func nudgeUpHeadroomEmitsBodyCue() {
        let engine = CueEngine()
        let body = BodySignal(hint: .nudgeUpHeadroom, confidence: 0.9, dominantRect: nil)
        let cue = engine.process(frame: makeBodyFrame(body))
        #expect(cue?.text == CueText.nudgeUpHeadroom)
        #expect(cue?.priority == .body)
    }

    // MARK: - Test 7: goodBody → silence

    @Test("goodBody body signal → CueEngine returns nil (silence)")
    func goodBodyProducesNil() {
        let engine = CueEngine()
        let body = BodySignal(hint: .goodBody, confidence: 0.9, dominantRect: nil)
        let cue = engine.process(frame: makeBodyFrame(body))
        #expect(cue == nil)
    }

    // MARK: - Test 8: Zero-false-cue baseline

    @Test("Zero-false-cue baseline: nil body and all tier-0 signals clean → CueEngine returns nil")
    func zeroPalsePositiveBaseline() {
        let engine = CueEngine()
        let cleanFrame = SignalFrame(
            timestamp: 1.0,
            tilt: TiltSignal(angleDegrees: 0.0, isLevel: true),
            blur: BlurSignal(sharpnessScore: 100.0, isBlurry: false),
            exposure: ExposureSignal(
                shadowClipFraction: 0.01,
                highlightClipFraction: 0.01,
                level: .ok
            ),
            framing: FramingSignal(subjectBox: nil, hint: .goodFrame),
            body: nil
        )
        #expect(engine.process(frame: cleanFrame) == nil)
    }

    // MARK: - Bonus Test 9: noPersonPresent sentinel → silence

    @Test("BodySignal.noPersonPresent sentinel → CueEngine returns nil (silence)")
    func noPersonPresentProducesNil() {
        let engine = CueEngine()
        let cue = engine.process(frame: makeBodyFrame(.noPersonPresent))
        #expect(cue == nil)
    }

    // MARK: - Bonus Test 10: lensObstructed fires after repeat-suppression interval expires

    @Test("lensObstructed fires again after repeat-suppression interval expires")
    func lensObstructedRefirersAfterRepeatInterval() {
        let clock = BodyTestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 1.0,
            minRepeatIntervalSeconds: 5.0,
            clock: { clock.now }
        )
        let body = BodySignal(hint: .lensObstructed, confidence: 0.9, dominantRect: nil)
        let frame = makeBodyFrame(body)

        // First emission — should fire.
        let cue1 = engine.process(frame: frame)
        #expect(cue1?.text == CueText.lensObstructed)

        // Advance past cooldown but within minRepeat — should be suppressed.
        clock.advance(by: 2.0)
        let cue2 = engine.process(frame: frame)
        #expect(cue2 == nil)

        // Advance past minRepeatIntervalSeconds — should fire again.
        clock.advance(by: 4.0)  // total 6.0 > minRepeatIntervalSeconds (5.0)
        let cue3 = engine.process(frame: frame)
        #expect(cue3?.text == CueText.lensObstructed)
    }
}
