import CoreGraphics
import Testing
@testable import PicPal

// MARK: - CueEvaluatorGroupTests

/// Tests for the M6-3 group path in `CueEvaluator.evaluate(frame:predictive:)`.
///
/// Covers:
/// - Group mode activation and suppression of single-subject body cues
/// - Lens obstruction is never suppressed, even in group mode
/// - All five group cue conditions in isolation
/// - Priority ordering when multiple conditions are true
/// - Boundary / silent cases (at-threshold and fall-through to aesthetic)
struct CueEvaluatorGroupTests {

    // MARK: - Helpers

    /// A `GroupPresence` whose geometry satisfies all thresholds (no cue emitted).
    private func goodGroupPresence() -> GroupPresence {
        GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.8,
            leftMargin: 0.1,
            rightMargin: 0.1,
            headroomFraction: 0.3
        )
    }

    private func groupFrame(
        group: GroupPresence,
        body: BodySignal? = nil,
        aesthetic: AestheticSignal? = nil
    ) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            body: body,
            aesthetic: aesthetic,
            groupPresence: group
        )
    }

    private func bodyOnly(hint: BodyHint) -> SignalFrame {
        SignalFrame(
            timestamp: 0,
            body: BodySignal(hint: hint, confidence: 0.9, dominantRect: nil)
        )
    }

    // MARK: - Group mode activation / suppression

    @Test("body cues suppressed when groupPresence is non-nil — no cue returned")
    func bodyCuesSuppressedInGroupMode() {
        let evaluator = CueEvaluator()
        let frame = groupFrame(
            group: goodGroupPresence(),
            body: BodySignal(hint: .awkwardCrop, confidence: 0.9, dominantRect: nil)
        )
        #expect(evaluator.evaluate(frame: frame) == nil)
    }

    @Test("single-subject awkwardCrop fires when groupPresence is nil")
    func singleSubjectBodyCueFiresWhenNoGroupPresence() {
        let evaluator = CueEvaluator()
        let cue = evaluator.evaluate(frame: bodyOnly(hint: .awkwardCrop))
        #expect(cue?.text == CueText.awkwardCrop)
        #expect(cue?.priority == .body)
    }

    @Test("lensObstructed fires in group mode — obstruction is never suppressed")
    func lensObstructionFiresInGroupMode() {
        let evaluator = CueEvaluator()
        let frame = groupFrame(
            group: goodGroupPresence(),
            body: BodySignal(hint: .lensObstructed, confidence: 0.9, dominantRect: nil)
        )
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.text == CueText.lensObstructed)
        #expect(cue?.priority == .obstruction)
    }

    // MARK: - Group cue emission (each condition in isolation)

    @Test("leftMargin = 0.02 (< edgeCutoffThreshold) → groupCutOffLeft")
    func leftEdgeCutoffFiresGroupCue() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.02, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.8,
            leftMargin: 0.02,
            rightMargin: 0.1,
            headroomFraction: 0.3
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupCutOffLeft)
        #expect(cue?.priority == .body)
        #expect(cue?.sourceTier == .tier05)
    }

    @Test("rightMargin = 0.02 (< edgeCutoffThreshold) → groupCutOffRight")
    func rightEdgeCutoffFiresGroupCue() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.8,
            leftMargin: 0.1,
            rightMargin: 0.02,
            headroomFraction: 0.3
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupCutOffRight)
        #expect(cue?.priority == .body)
        #expect(cue?.sourceTier == .tier05)
    }

    @Test("spreadFraction = 0.95 (> spreadWideThreshold 0.80) → groupSpreadWide")
    func spreadWideCueFiresAboveThreshold() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.95,
            leftMargin: 0.1,
            rightMargin: 0.1,
            headroomFraction: 0.3
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupSpreadWide)
    }

    @Test("spreadFraction = 0.25 (< learnInThreshold 0.35) → groupLearnIn")
    func learnInCueFiresBelowThreshold() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.25, height: 0.6),
            spreadFraction: 0.25,
            leftMargin: 0.1,
            rightMargin: 0.1,
            headroomFraction: 0.3
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupLearnIn)
    }

    @Test("headroomFraction = 0.05 (< highGroupThreshold 0.12) → groupTooHigh")
    func groupTooHighCueFiresBelowThreshold() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.8,
            leftMargin: 0.1,
            rightMargin: 0.1,
            headroomFraction: 0.05
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupTooHigh)
    }

    // MARK: - Priority ordering

    @Test("leftMargin = 0.02 AND spreadFraction = 0.95 → groupCutOffLeft wins")
    func leftEdgeCutoffOutranksSpreadWide() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.02, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.95,
            leftMargin: 0.02,
            rightMargin: 0.1,
            headroomFraction: 0.3
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupCutOffLeft)
    }

    @Test("rightMargin = 0.02 AND spreadFraction = 0.40 → groupCutOffRight wins")
    func rightEdgeCutoffOutranksLearnIn() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.40,
            leftMargin: 0.1,
            rightMargin: 0.02,
            headroomFraction: 0.3
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupCutOffRight)
    }

    @Test("spreadFraction = 0.95 AND headroomFraction = 0.05 → groupSpreadWide wins")
    func spreadWideOutranksLearnIn() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.95,
            leftMargin: 0.1,
            rightMargin: 0.1,
            headroomFraction: 0.05
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue?.text == CueText.groupSpreadWide)
    }

    // MARK: - Boundary / silent cases

    @Test("all group geometry within thresholds + aesthetic.remark → aesthetic cue returned")
    func allGroupGeometryGoodFallsThroughToAesthetic() {
        let evaluator = CueEvaluator()
        let aesthetic = AestheticSignal(remark: "nice golden-hour light", confidence: 0.9, hint: .remark)
        let frame = groupFrame(group: goodGroupPresence(), aesthetic: aesthetic)
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.text == "nice golden-hour light")
        #expect(cue?.priority == .aesthetic)
    }

    @Test("leftMargin = 0.04 exactly (not < edgeCutoffThreshold) → no group edge cue")
    func groupGeometryAtExactThresholdsNoGroupCue() {
        let evaluator = CueEvaluator()
        let group = GroupPresence(
            personCount: 2,
            unionBoundingBox: CGRect(x: 0.04, y: 0.1, width: 0.8, height: 0.6),
            spreadFraction: 0.8,   // within (not > 0.80, not < 0.35)
            leftMargin: 0.04,      // exactly at threshold — not strictly less than
            rightMargin: 0.1,
            headroomFraction: 0.3  // within (not < 0.12)
        )
        let cue = evaluator.evaluate(frame: groupFrame(group: group))
        #expect(cue == nil)
    }
}
