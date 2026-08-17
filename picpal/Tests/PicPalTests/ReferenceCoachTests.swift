import Foundation
import Testing
@testable import PicPal

// MARK: - ReferenceCoachTests

struct ReferenceCoachTests {

    private let coach = ReferenceCoach()

    // MARK: - Match confirmation

    @Test("isNewMatch = true overrides all deltas and returns matched cue")
    func newMatchReturnsMatchedCue() {
        let delta = PoseDelta(
            horizontalOffset: 0.5,    // Way out of threshold
            verticalOffset: 0.5,      // Way out of threshold
            headroomDelta: 0.5,       // Way out of threshold
            scaleDelta: 0.5,          // Way out of threshold
            faceYawDelta: 1.0         // Way out of threshold
        )
        let cue = coach.cue(from: delta, isNewMatch: true)
        #expect(cue != nil)
        #expect(cue?.text == ReferenceCoach.CueText.matched)
        #expect(cue?.priority == .body)
        #expect(cue?.sourceTier == .tier05)
    }

    // MARK: - All within threshold

    @Test("All components within threshold → nil (silence)")
    func allWithinThresholdReturnsNil() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.05,
            faceYawDelta: 0.01
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue == nil)
    }

    @Test("All components at exactly zero → nil (perfect match)")
    func zeroDeltaReturnsNil() {
        let delta = PoseDelta(
            horizontalOffset: 0.0,
            verticalOffset: 0.0,
            headroomDelta: 0.0,
            scaleDelta: 0.0,
            faceYawDelta: 0.0
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue == nil)
    }

    @Test("isNewMatch = true with all components within threshold → still returns matched cue")
    func newMatchPlusPerfectDeltaStillReturnsMatched() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.05,
            faceYawDelta: 0.01
        )
        let cue = coach.cue(from: delta, isNewMatch: true)
        #expect(cue?.text == ReferenceCoach.CueText.matched)
    }

    // MARK: - Priority 1: Face Yaw (highest priority)

    @Test("Face yaw out of threshold (positive, turned right) → faceCamera cue")
    func faceYawPositiveReturnsFaceCamera() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.05,
            faceYawDelta: 0.2  // > 0.15 threshold
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.faceCamera)
        #expect(cue?.priority == .body)
    }

    @Test("Face yaw out of threshold (negative, turned left) → faceCamera cue")
    func faceYawNegativeReturnsFaceCamera() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.05,
            faceYawDelta: -0.2  // < -0.15 threshold
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.faceCamera)
    }

    @Test("Face yaw within threshold but scale out → scale cue returned (yaw checked first)")
    func faceYawWithinButScaleOutYieldsFaceYawNilAndScaleCue() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.2,   // > 0.15 threshold
            faceYawDelta: 0.1  // < 0.15 threshold
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        // Face yaw is within threshold, so it doesn't trigger; scale is checked next
        #expect(cue?.text == ReferenceCoach.CueText.stepCloser)
    }

    @Test("Face yaw nil (no face detected) → skipped, next priority evaluated")
    func faceYawNilSkipsAndEvaluatesScale() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.2,
            faceYawDelta: nil
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.stepCloser)
    }

    // MARK: - Priority 2: Scale

    @Test("Scale out of threshold (positive, too far) → stepCloser cue")
    func scalePositiveReturnsStepCloser() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.2  // > 0.15 threshold
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.stepCloser)
        #expect(cue?.priority == .body)
    }

    @Test("Scale out of threshold (negative, too close) → stepBack cue")
    func scaleNegativeReturnsStepBack() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: -0.2  // < -0.15 threshold
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.stepBack)
    }

    @Test("Scale within threshold but horizontal out → horizontal cue")
    func scaleWithinButHorizontalOut() {
        let delta = PoseDelta(
            horizontalOffset: 0.2,   // > 0.08 threshold
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.1  // < 0.15 threshold
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.moveLeft)
    }

    // MARK: - Priority 3: Horizontal

    @Test("Horizontal out of threshold (positive, too far right) → moveLeft cue")
    func horizontalPositiveReturnsMoveLeft() {
        let delta = PoseDelta(
            horizontalOffset: 0.2,   // > 0.08 threshold
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.moveLeft)
        #expect(cue?.priority == .body)
    }

    @Test("Horizontal out of threshold (negative, too far left) → moveRight cue")
    func horizontalNegativeReturnsMoveRight() {
        let delta = PoseDelta(
            horizontalOffset: -0.2,  // < -0.08 threshold
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.moveRight)
    }

    @Test("Horizontal within threshold but vertical out → vertical cue")
    func horizontalWithinButVerticalOut() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.2,   // > 0.08 threshold
            headroomDelta: 0.01,
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.tiltDown)
    }

    // MARK: - Priority 4: Vertical

    @Test("Vertical out of threshold (positive, too high) → tiltDown cue")
    func verticalPositiveReturnsTiltDown() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.2,   // > 0.08 threshold
            headroomDelta: 0.01,
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.tiltDown)
        #expect(cue?.priority == .body)
    }

    @Test("Vertical out of threshold (negative, too low) → tiltUp cue")
    func verticalNegativeReturnsTiltUp() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: -0.2,  // < -0.08 threshold
            headroomDelta: 0.01,
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.tiltUp)
    }

    // MARK: - Priority 5: Headroom (lowest priority)

    @Test("Headroom out of threshold (positive, too much space) → moreHeadroom cue")
    func headroomPositiveReturnsMoreHeadroom() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.2,   // > 0.08 threshold
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.moreHeadroom)
        #expect(cue?.priority == .body)
    }

    @Test("Headroom out of threshold (negative, too little space) → lessHeadroom cue")
    func headroomNegativeReturnsLessHeadroom() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: -0.2,  // < -0.08 threshold
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.lessHeadroom)
    }

    // MARK: - Priority tie-breaking

    @Test("Multiple components out of threshold → highest priority (face yaw) wins")
    func multipleOutFaceYawWins() {
        let delta = PoseDelta(
            horizontalOffset: 0.2,   // out
            verticalOffset: 0.2,     // out
            headroomDelta: 0.2,      // out
            scaleDelta: 0.2,         // out
            faceYawDelta: 0.2        // out
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.faceCamera)
    }

    @Test("Scale and horizontal both out → scale (priority 2) wins over horizontal (priority 3)")
    func scaleWinsOverHorizontal() {
        let delta = PoseDelta(
            horizontalOffset: 0.2,   // out
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.2          // out, higher priority
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.stepCloser)
    }

    @Test("Horizontal and vertical both out → horizontal (priority 3) wins over vertical (priority 4)")
    func horizontalWinsOverVertical() {
        let delta = PoseDelta(
            horizontalOffset: 0.2,   // out, higher priority
            verticalOffset: 0.2,     // out
            headroomDelta: 0.01,
            scaleDelta: 0.05
        )
        let cue = coach.cue(from: delta, isNewMatch: false)
        #expect(cue?.text == ReferenceCoach.CueText.moveLeft)
    }

}
