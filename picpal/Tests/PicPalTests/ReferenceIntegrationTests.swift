import Testing
import CoreGraphics
@testable import PicPal

// MARK: - ReferenceIntegrationTests

/// Integration tests for the reference-photo coaching pipeline.
///
/// Covers:
///   1. computePoseDelta — zero result when live signal has no subject rect
///   2. computePoseDelta — expected horizontal offset when subject is shifted left
///   3. matchCounter — increments on 7 consecutive within-threshold frames (not yet matched)
///   4. matchCounter — triggers isMatched after 8 consecutive within-threshold frames
///   5. matchCounter — resets count and isMatched after one outside-threshold frame
///   6. matchCue     — fires exactly once per match event (transition only)
@Suite("ReferenceIntegration")
struct ReferenceIntegrationTests {

    // MARK: - Helpers

    /// Returns a `ReferencePose` with configurable subject position.
    private func makeReferencePose(
        centerX: Float = 0.5,
        centerY: Float = 0.5,
        heightFraction: Float = 0.6,
        headroomFraction: Float = 0.15
    ) -> ReferencePose {
        ReferencePose(
            bodyKeypoints: ["root": CGPoint(x: CGFloat(centerX), y: CGFloat(centerY))],
            faceCenter: nil,
            faceYaw: nil,
            subjectBoundingBox: CGRect(
                x: CGFloat(centerX) - 0.2,
                y: CGFloat(centerY) - 0.3,
                width: 0.4,
                height: CGFloat(heightFraction)
            ),
            subjectCenterX: centerX,
            subjectCenterY: centerY,
            subjectHeightFraction: heightFraction,
            headroomFraction: headroomFraction
        )
    }

    /// Returns a `BodySignal` whose `dominantRect` centres at (midX, midY) in UIKit coords.
    private func makeBodySignal(midX: CGFloat, midY: CGFloat = 0.5, height: CGFloat = 0.6) -> BodySignal {
        let width: CGFloat = 0.4
        let rect = CGRect(
            x: midX - width / 2,
            y: midY - height / 2,
            width: width,
            height: height
        )
        return BodySignal(hint: .goodBody, confidence: 0.9, dominantRect: rect)
    }

    /// Simulates the per-frame match-counting logic from ContentView+Reference.swift.
    ///
    /// Matches the exact logic used in `makeReferenceCoachingCallback` so that these tests
    /// remain in sync with the production implementation.
    private func simulateFrame(
        delta: PoseDelta,
        matchCount: inout Int,
        isMatched: inout Bool,
        coach: ReferenceCoach,
        cueCount: inout Int
    ) {
        if delta.isWithinThreshold {
            matchCount += 1
        } else {
            matchCount = 0
            isMatched = false
        }
        let wasMatched = isMatched
        if matchCount >= referenceMatchConfirmationFrames && !isMatched {
            isMatched = true
        }
        let isNewMatchEvent = !wasMatched && isMatched
        if coach.cue(from: delta, isNewMatch: isNewMatchEvent) != nil {
            cueCount += 1
        }
    }

    // MARK: - Test 1: computePoseDelta zeros when no subject rect

    @Test("computePoseDelta returns all-zero delta when live signal has no dominantRect")
    func computePoseDelta_returnsZeroWhenNoMatchingKeypoints() {
        let pose = makeReferencePose()
        let emptySignal = BodySignal.noPersonPresent   // dominantRect is nil

        let delta = computePoseDelta(referencePose: pose, liveLandmarks: emptySignal)

        #expect(delta.horizontalOffset == 0)
        #expect(delta.verticalOffset == 0)
        #expect(delta.headroomDelta == 0)
        #expect(delta.scaleDelta == 0)
        #expect(delta.faceYawDelta == nil)
    }

    // MARK: - Test 2: computePoseDelta horizontal offset

    @Test("computePoseDelta returns horizontalOffset ≈ -0.3 when subject is 0.3 to the left")
    func computePoseDelta_returnsExpectedHorizontalOffset() {
        let refCenterX: Float = 0.5
        let pose = makeReferencePose(centerX: refCenterX)

        // Live subject is 0.3 to the left of reference (UIKit X is same direction as Vision X)
        let liveSignal = makeBodySignal(midX: CGFloat(refCenterX) - 0.3)

        let delta = computePoseDelta(referencePose: pose, liveLandmarks: liveSignal)

        #expect(abs(delta.horizontalOffset - (-0.3)) < 0.01,
                "Expected horizontalOffset ≈ -0.3, got \(delta.horizontalOffset)")
    }

    // MARK: - Test 3: match counter increments on within-threshold frames

    @Test("referenceMatchCount == 7 after 7 consecutive within-threshold frames, isMatched == false")
    func matchCounterIncrementsOnWithinThreshold() {
        var matchCount = 0
        var isMatched = false
        let coach = ReferenceCoach()
        var cueCount = 0

        let inThreshold = PoseDelta(horizontalOffset: 0, verticalOffset: 0,
                                    headroomDelta: 0, scaleDelta: 0)
        for _ in 0..<7 {
            simulateFrame(delta: inThreshold, matchCount: &matchCount,
                          isMatched: &isMatched, coach: coach, cueCount: &cueCount)
        }

        #expect(matchCount == 7)
        #expect(!isMatched)
    }

    // MARK: - Test 4: match triggers at exactly 8 frames

    @Test("isReferenceMatched becomes true after exactly 8 consecutive within-threshold frames")
    func matchCounterTriggersMatchAt8Frames() {
        var matchCount = 0
        var isMatched = false
        let coach = ReferenceCoach()
        var cueCount = 0

        let inThreshold = PoseDelta(horizontalOffset: 0, verticalOffset: 0,
                                    headroomDelta: 0, scaleDelta: 0)
        for _ in 0..<8 {
            simulateFrame(delta: inThreshold, matchCount: &matchCount,
                          isMatched: &isMatched, coach: coach, cueCount: &cueCount)
        }

        #expect(isMatched)
    }

    // MARK: - Test 5: outside-threshold frame resets counter

    @Test("referenceMatchCount == 0 and isMatched == false after outside-threshold frame")
    func matchCounterResetsOnOutsideThreshold() {
        var matchCount = 0
        var isMatched = false
        let coach = ReferenceCoach()
        var cueCount = 0

        let inThreshold = PoseDelta(horizontalOffset: 0, verticalOffset: 0,
                                    headroomDelta: 0, scaleDelta: 0)
        // 5 matching frames
        for _ in 0..<5 {
            simulateFrame(delta: inThreshold, matchCount: &matchCount,
                          isMatched: &isMatched, coach: coach, cueCount: &cueCount)
        }

        // 1 outside-threshold frame
        let outsideThreshold = PoseDelta(horizontalOffset: 0.5, verticalOffset: 0,
                                         headroomDelta: 0, scaleDelta: 0)
        simulateFrame(delta: outsideThreshold, matchCount: &matchCount,
                      isMatched: &isMatched, coach: coach, cueCount: &cueCount)

        #expect(matchCount == 0)
        #expect(!isMatched)
    }

    // MARK: - Test 6: match cue fires exactly once per match event

    @Test("Match cue fires exactly once for a match event; 2 additional within-threshold frames produce no cue")
    func matchCueFiresOncePerMatchEvent() {
        var matchCount = 0
        var isMatched = false
        let coach = ReferenceCoach()
        var cueCount = 0

        let inThreshold = PoseDelta(horizontalOffset: 0, verticalOffset: 0,
                                    headroomDelta: 0, scaleDelta: 0)

        // 8 frames to trigger the match event — cue fires exactly once on frame 8
        for _ in 0..<8 {
            simulateFrame(delta: inThreshold, matchCount: &matchCount,
                          isMatched: &isMatched, coach: coach, cueCount: &cueCount)
        }

        // 2 additional within-threshold frames — should produce no cue (already matched)
        for _ in 0..<2 {
            simulateFrame(delta: inThreshold, matchCount: &matchCount,
                          isMatched: &isMatched, coach: coach, cueCount: &cueCount)
        }

        #expect(cueCount == 1)
    }
}
