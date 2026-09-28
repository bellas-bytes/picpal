import Foundation
import Testing
import Vision
@testable import PicPal

struct SelfiePoseCoachTests {
    private func reference(hand: CGPoint, roll: Double = 0) -> ReferencePose {
        ReferencePose(bodyKeypoints: [:], faceCenter: CGPoint(x: 0.5, y: 0.6), faceYaw: nil,
            subjectBoundingBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2),
            subjectCenterX: 0.5, subjectCenterY: 0.6, subjectHeightFraction: 0.2, headroomFraction: 0.3,
            faceBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2), framingDomain: .face,
            selfie: SelfiePoseObservation(roll: roll, hands: [.init(anchor: hand, victory: nil)], handsAvailable: true))
    }
    private func live(hand: CGPoint?, roll: Double = 0, time: Double = 1) -> LivePoseObservation {
        LivePoseObservation(capturedAt: time, geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1,
            faceBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2),
            selfie: SelfiePoseObservation(roll: roll, hands: hand.map { [.init(anchor: $0, victory: nil)] } ?? [], handsAvailable: true))
    }
    @Test func croppedSelfieReceivesHandCueWithoutHipsOrWrist() {
        var comparator = ReferenceLocalComparator()
        let output = comparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55)), live: live(hand: CGPoint(x: 0.35, y: 0.4)))
        #expect(output.action?.instruction == "Raise your hand toward the reference position")
        #expect(abs((output.guidanceTarget?.point.y ?? 0) - 0.45) < 0.00001)
        #expect(output.poseAligned == nil)
    }
    @Test func widestSelfieContinuesHeadCoachingWithoutMatchingFraming() {
        let ref = reference(hand: CGPoint(x: 0.35, y: 0.55), roll: 0.4)
        let frame = LivePoseObservation(capturedAt: 1, geometryRevision: 1, personBox: nil,
            joints: [:], subjectCount: 1, faceBox: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.4),
            selfie: SelfiePoseObservation(roll: 0))
        var comparator = ReferenceLocalComparator()
        let normal = comparator.compare(reference: ref, live: frame)
        #expect(normal.action?.direction == "selfie_head_tilt")
        let limited = comparator.compare(reference: ref, live: frame, selfieAtMinimumZoom: true)
        #expect(limited.action?.direction == "selfie_head_tilt")
        #expect(!limited.framingAligned)
        #expect(limited.poseAligned == nil)
        #expect(limited.dimensions.first { $0.dimension == .framing }?.status == .different)
        var coordinator = ReferenceCoachingCoordinator()
        let decision = coordinator.update(ReferenceCoachingInput(sessionID: UUID(), generation: 1,
            geometryRevision: 1, now: 1, local: limited, cloudAvailability: .localOnly, captureSafe: true))
        #expect(decision.action?.direction == "selfie_head_tilt")
        #expect(!decision.referenceMatched)
        #expect(!decision.allowsAutoCapture)
    }
    @Test func cloudDistanceCueYieldsToMeasuredSelfiePoseAtWidestView() {
        var coordinator = ReferenceCoachingCoordinator()
        var comparator = ReferenceLocalComparator()
        let session = UUID()
        let envelope = ReferenceEnvelope(sessionID: session, generation: 1, requestID: UUID(),
            capturedAt: 1, geometryRevision: 1)
        let dimension = ReferenceDimensionComparison(dimension: .framing, status: .different,
            referenceEvidence: "Small face", liveEvidence: "Larger face", confidence: 0.9)
        let cloudAction = ReferenceAction(id: "distance", dimension: .framing, actor: .photographer,
            direction: "move_back", instruction: "Move farther away", expectedChange: "Match framing", confidence: 0.9)
        let comparison = ReferenceComparison(schemaVersion: 1, dimensions: [dimension], action: cloudAction)
        let initial = LocalReferenceEvidence(capturedAt: 1, geometryRevision: 1, framingAligned: false,
            poseAligned: nil, dimensions: [dimension], action: nil, subjectPresent: true,
            analysisAvailable: true, subjectCount: 1)
        let first = coordinator.update(ReferenceCoachingInput(sessionID: session, generation: 1,
            geometryRevision: 1, now: 1, local: initial, comparison: (envelope, comparison),
            cloudAvailability: .available, captureSafe: true))
        #expect(first.action?.direction == "move_back")
        for time in [1.3, 1.6] {
            let frame = LivePoseObservation(capturedAt: time, geometryRevision: 1, personBox: nil,
                joints: [:], subjectCount: 1, faceBox: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.4),
                selfie: SelfiePoseObservation(roll: 0))
            let local = comparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55), roll: 0.4),
                live: frame, selfieAtMinimumZoom: true)
            let decision = coordinator.update(ReferenceCoachingInput(sessionID: session, generation: 1,
                geometryRevision: 1, now: time, local: local, comparison: (envelope, comparison),
                cloudAvailability: .available, captureSafe: true))
            if time == 1.3 {
                #expect(SelfieFramingAdvice.caption(direction: decision.action?.direction, zoom: 1, minimumZoom: 1)
                    == "Widest selfie view — match your head and hand pose")
            } else { #expect(decision.action?.direction == "selfie_head_tilt") }
            #expect(!decision.allowsAutoCapture)
            #expect(!decision.referenceMatched)
        }
    }
    @Test func widestSelfieWithoutPoseEvidenceKeepsHonestFramingMismatch() {
        var comparator = ReferenceLocalComparator()
        let frame = LivePoseObservation(capturedAt: 1, geometryRevision: 1, personBox: nil,
            joints: [:], subjectCount: 1, faceBox: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.4))
        let result = comparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55)),
            live: frame, selfieAtMinimumZoom: true)
        #expect(result.action == nil)
        #expect(!result.framingAligned)
        #expect(result.poseAligned == nil)
        #expect(result.guidanceTarget == nil)
    }
    @Test func supportedHeadCorrectionSurvivesLateralFramingMismatch() {
        var comparator = ReferenceLocalComparator()
        let frame = LivePoseObservation(capturedAt: 1, geometryRevision: 1, personBox: nil,
            joints: [:], subjectCount: 1, faceBox: CGRect(x: 0.65, y: 0.5, width: 0.2, height: 0.2),
            selfie: SelfiePoseObservation(roll: 0))
        let result = comparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55), roll: 0.4),
            live: frame, selfieAtMinimumZoom: true)
        #expect(result.action?.direction == "selfie_head_tilt")
        #expect(!result.framingAligned)
    }
    @Test func missingHandDoesNotPreserveMovementCue() {
        var comparator = ReferenceLocalComparator()
        let ref = reference(hand: CGPoint(x: 0.35, y: 0.55))
        _ = comparator.compare(reference: ref, live: live(hand: CGPoint(x: 0.35, y: 0.4)))
        let missing = comparator.compare(reference: ref, live: live(hand: nil, time: 1.3))
        #expect(missing.action == nil)
        #expect(missing.guidanceTarget == nil)
    }
    @Test func partialAlignmentNeverCertifiesPose() {
        var comparator = ReferenceLocalComparator()
        let output = comparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55)), live: live(hand: CGPoint(x: 0.35, y: 0.55)))
        #expect(output.poseAligned == nil)
        #expect(output.alignedPoseDetails.contains("selfie_hand_position"))
    }
    @Test func unavailableGestureDoesNotGenerateGestureSuccess() {
        let output = SelfiePoseComparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55)), live: live(hand: CGPoint(x: 0.35, y: 0.55)))
        #expect(!output.alignedDetails.contains("selfie_gesture"))
        #expect(SelfiePoseTracker.victory([:]) == nil)
    }
    @Test func realPeaceSignAnchorSurvivesOccludedWrist() {
        typealias J = VNHumanHandPoseObservation.JointName
        let joints = [
            J.wrist.rawValue.rawValue: LivePoseJoint(point: CGPoint(x: 0.3, y: 0.35), confidence: 0.18164),
            J.indexMCP.rawValue.rawValue: LivePoseJoint(point: CGPoint(x: 0.379757, y: 0.363338), confidence: 0.5923),
            J.middleMCP.rawValue.rawValue: LivePoseJoint(point: CGPoint(x: 0.373092, y: 0.361105), confidence: 0.5586)
        ]
        let hand = SelfiePoseTracker.adapt(joints, imageAspectRatio: 4.0 / 3.0)
        #expect(hand != nil)
        #expect(hand?.victory == nil)
        #expect(abs((hand?.anchor.x ?? 0) - 0.3764245) < 0.00001)
    }
    @Test func headRollUsesConcretePreviewDirection() {
        let result = SelfiePoseComparator.compare(reference: reference(hand: CGPoint(x: 0.3, y: 0.5), roll: 0.3), live: live(hand: nil))
        #expect(result.action?.instruction == "Tilt the top of your head toward the left side of the preview")
    }
    @Test func lowConfidenceSecondHandRemainsAmbiguous() {
        let base = live(hand: CGPoint(x: 0.35, y: 0.4))
        let ambiguous = LivePoseObservation(capturedAt: 1, geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1,
            faceBox: base.faceBox, selfie: SelfiePoseObservation(hands: base.selfie!.hands, handsAvailable: true, detectedHandCount: 2))
        let result = SelfiePoseComparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55)), live: ambiguous)
        #expect(result.action == nil)
        #expect(!result.availableDetails.contains("selfie_hand_position"))
    }
    @Test func directionJitterRequiresConsecutiveObservationsAndUnknownClearsCue() {
        var comparator = ReferenceLocalComparator()
        var coordinator = ReferenceCoachingCoordinator()
        let session = UUID()
        let ref = reference(hand: CGPoint(x: 0.35, y: 0.55))
        func input(_ local: LocalReferenceEvidence, time: Double) -> ReferenceCoachingInput {
            ReferenceCoachingInput(sessionID: session, generation: 1, geometryRevision: 1, now: time,
                local: local, cloudAvailability: .localOnly, captureSafe: true)
        }
        let first = comparator.compare(reference: ref, live: live(hand: CGPoint(x: 0.35, y: 0.4)))
        let firstDecision = coordinator.update(input(first, time: 1))
        let opposite = comparator.compare(reference: ref, live: live(hand: CGPoint(x: 0.35, y: 0.7), time: 1.3))
        let pending = coordinator.update(input(opposite, time: 1.3))
        #expect(pending.caption == firstDecision.caption)
        #expect(pending.guidanceTarget == nil)
        let unknown = comparator.compare(reference: ref, live: live(hand: nil, roll: 0.4, time: 1.6))
        let next = coordinator.update(input(unknown, time: 1.6))
        #expect(next.action?.direction == "selfie_head_tilt")
        #expect(!next.allowsAutoCapture)
    }
    @Test func progressNamesTheMeasuredDetail() {
        var comparator = ReferenceLocalComparator()
        var coordinator = ReferenceCoachingCoordinator()
        let session = UUID()
        let ref = reference(hand: CGPoint(x: 0.35, y: 0.55))
        for (time, hand) in [(1.0, CGPoint(x: 0.35, y: 0.4)), (1.3, CGPoint(x: 0.35, y: 0.55)), (1.6, CGPoint(x: 0.35, y: 0.55))] {
            let local = comparator.compare(reference: ref, live: live(hand: hand, time: time))
            let output = coordinator.update(ReferenceCoachingInput(sessionID: session, generation: 1,
                geometryRevision: 1, now: time, local: local, cloudAvailability: .localOnly, captureSafe: true))
            if time > 1 { #expect(output.progressCaption == "Your hand position now aligns") }
        }
    }
    @Test func oppositeYawDoesNotRecommendTurningFartherOnWrongSide() {
        let box = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2)
        let ref = ReferencePose(bodyKeypoints: [:], faceCenter: nil, faceYaw: nil,
            subjectBoundingBox: box, subjectCenterX: 0.5, subjectCenterY: 0.6,
            subjectHeightFraction: 0.2, headroomFraction: 0.3, faceBox: box, framingDomain: .face,
            selfie: SelfiePoseObservation(yaw: 0.5))
        let observed = LivePoseObservation(capturedAt: 1, geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1,
            faceBox: box, selfie: SelfiePoseObservation(yaw: -0.3))
        let result = SelfiePoseComparator.compare(reference: ref, live: observed)
        #expect(result.action?.instruction == "Turn your face toward the opposite side, as in the reference")
    }
    @Test func unspreadFingersCannotCertifyVictory() {
        typealias J = VNHumanHandPoseObservation.JointName
        let points: [(J, CGPoint)] = [
            (.wrist, .init(x: 0.5, y: 0.2)),
            (.indexMCP, .init(x: 0.45, y: 0.4)), (.indexPIP, .init(x: 0.45, y: 0.55)), (.indexTip, .init(x: 0.45, y: 0.75)),
            (.middleMCP, .init(x: 0.55, y: 0.4)), (.middlePIP, .init(x: 0.55, y: 0.55)), (.middleTip, .init(x: 0.55, y: 0.75)),
            (.ringMCP, .init(x: 0.60, y: 0.4)), (.ringPIP, .init(x: 0.62, y: 0.5)), (.ringTip, .init(x: 0.61, y: 0.35)),
            (.littleMCP, .init(x: 0.65, y: 0.38)), (.littlePIP, .init(x: 0.68, y: 0.46)), (.littleTip, .init(x: 0.66, y: 0.32))
        ]
        let joints = Dictionary(uniqueKeysWithValues: points.map { ($0.0.rawValue.rawValue, LivePoseJoint(point: $0.1, confidence: 0.9)) })
        #expect(SelfiePoseTracker.victory(joints) == nil)
    }
    @Test func nanHeadAngleDoesNotProduceInstruction() {
        let output = SelfiePoseComparator.compare(reference: reference(hand: CGPoint(x: 0.35, y: 0.55), roll: .nan), live: live(hand: nil))
        #expect(output.action == nil)
        #expect(output.measuredDetails == 0)
    }
}
