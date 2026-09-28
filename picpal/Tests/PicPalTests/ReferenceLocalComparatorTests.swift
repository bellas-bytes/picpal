import Foundation
import Testing
import Vision
@testable import PicPal

struct ReferenceLocalComparatorTests {
    private func joints(raised: Bool = false) -> [String: CGPoint] {
        let values: [(VNHumanBodyPoseObservation.JointName, CGFloat, CGFloat)] = [
            (.leftShoulder, 0.4, 0.7), (.rightShoulder, 0.6, 0.7),
            (.leftHip, 0.43, 0.45), (.rightHip, 0.57, 0.45),
            (.leftElbow, 0.3, raised ? 0.8 : 0.55), (.rightElbow, 0.7, 0.55),
            (.leftWrist, 0.25, raised ? 0.9 : 0.4), (.rightWrist, 0.75, 0.4),
            (.leftKnee, 0.43, 0.28), (.rightKnee, 0.57, 0.28),
            (.leftAnkle, 0.43, 0.1), (.rightAnkle, 0.57, 0.1)]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.0.rawValue.rawValue, CGPoint(x: $0.1, y: $0.2)) })
    }
    private let box = CGRect(x: 0.2, y: 0.05, width: 0.6, height: 0.9)
    private func reference(_ points: [String: CGPoint]) -> ReferencePose {
        ReferencePose(bodyKeypoints: points, faceCenter: nil, faceYaw: nil, subjectBoundingBox: box,
                      subjectCenterX: 0.5, subjectCenterY: 0.5, subjectHeightFraction: 0.9, headroomFraction: 0.05)
    }
    private func live(_ points: [String: CGPoint], count: Int = 1) -> LivePoseObservation {
        LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: box,
                            joints: points.mapValues { LivePoseJoint(point: $0, confidence: 1) }, subjectCount: count)
    }
    @Test func identicalBoxDifferentArm() {
        var comparator = ReferenceLocalComparator()
        let result = comparator.compare(reference: reference(joints(raised: true)), live: live(joints()))
        #expect(result.framingAligned)
        #expect(result.poseAligned == false)
        #expect(result.action?.actor == .subject)
        #expect(result.action?.direction == "raise_left_arm")
    }
    @Test func minimumSelfieZoomDoesNotBypassBodyFraming() {
        var comparator = ReferenceLocalComparator()
        let small = CGRect(x: 0.35, y: 0.275, width: 0.3, height: 0.45)
        let ref = ReferencePose(bodyKeypoints: joints(raised: true), faceCenter: nil, faceYaw: nil,
            subjectBoundingBox: small, subjectCenterX: 0.5, subjectCenterY: 0.5,
            subjectHeightFraction: 0.45, headroomFraction: 0.275)
        let result = comparator.compare(reference: ref, live: live(joints()), selfieAtMinimumZoom: true)
        #expect(result.action?.direction == "move_back")
        #expect(!result.framingAligned)
    }
    @Test func missingWristIsUnknown() {
        var points = joints()
        points.removeValue(forKey: VNHumanBodyPoseObservation.JointName.leftWrist.rawValue.rawValue)
        var comparator = ReferenceLocalComparator()
        #expect(comparator.compare(reference: reference(joints()), live: live(points)).poseAligned == nil)
    }
    @Test func multiplePeopleAreUnknown() {
        var comparator = ReferenceLocalComparator()
        #expect(comparator.compare(reference: reference(joints()), live: live(joints(), count: 2)).poseAligned == nil)
    }
    @Test func seatedLegsDoNotMatchStanding() {
        var points = joints()
        points[VNHumanBodyPoseObservation.JointName.leftKnee.rawValue.rawValue] = CGPoint(x: 0.2, y: 0.45)
        var comparator = ReferenceLocalComparator()
        #expect(comparator.compare(reference: reference(joints()), live: live(points)).poseAligned != true)
    }
    @Test func completeSupportedPoseMatches() {
        var comparator = ReferenceLocalComparator()
        #expect(comparator.compare(reference: reference(joints()), live: live(joints())).poseAligned == true)
    }
    @Test func reverseArmCorrection() {
        var comparator = ReferenceLocalComparator()
        let result = comparator.compare(reference: reference(joints()), live: live(joints(raised: true)))
        #expect(result.action?.direction == "lower_left_arm")
    }
    @Test func horizontalFramingDirectionsAndMirroring() {
        for delta in [-0.12, 0.12] {
            for mirrored in [false, true] {
                var comparator = ReferenceLocalComparator()
                let actual = box.offsetBy(dx: delta, dy: 0)
                let pixels = actual
                let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: pixels, joints: [:],
                    subjectCount: 1, geometry: ReferenceGeometry(isMirrored: mirrored))
                let result = comparator.compare(reference: reference(joints()), live: frame)
                #expect(result.action?.direction == ((mirrored ? -delta : delta) > 0 ? "aim_right" : "aim_left"))
            }
        }
    }
    @Test func cropEdgeAndLowConfidenceCannotMatch() {
        let key = VNHumanBodyPoseObservation.JointName.leftWrist.rawValue.rawValue
        for confidence in [Float(0.2), Float(1)] {
            var values = joints().mapValues { LivePoseJoint(point: $0, confidence: 1) }
            values[key] = LivePoseJoint(point: CGPoint(x: confidence == 1 ? 0 : 0.25, y: 0.4), confidence: confidence)
            var comparator = ReferenceLocalComparator()
            let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: box, joints: values, subjectCount: 1)
            #expect(comparator.compare(reference: reference(joints()), live: frame).poseAligned == nil)
        }
    }
    @Test func geometryRevisionResetsFramingHysteresis() {
        var comparator = ReferenceLocalComparator()
        #expect(comparator.compare(reference: reference(joints()), live: live(joints())).framingAligned)
        let frame = LivePoseObservation(capturedAt: 10.3, geometryRevision: 2, personBox: box.offsetBy(dx: 0.065, dy: 0), joints: [:], subjectCount: 1)
        #expect(!comparator.compare(reference: reference(joints()), live: frame).framingAligned)
    }

    @Test func asymmetricReferenceUsesDisplayedMirroredPosition() {
        let targetBox = box.offsetBy(dx: -0.12, dy: 0)
        let target = ReferencePose(bodyKeypoints: joints(), faceCenter: nil, faceYaw: nil,
            subjectBoundingBox: targetBox, subjectCenterX: Float(targetBox.midX), subjectCenterY: 0.5,
            subjectHeightFraction: 0.9, headroomFraction: 0.05)
        let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: targetBox,
            joints: [:], subjectCount: 1, geometry: ReferenceGeometry(isMirrored: true))
        var comparator = ReferenceLocalComparator()
        #expect(comparator.compare(reference: target, live: frame).framingAligned)
    }

    @Test func torsoLeanNamesDisplayedDirection() {
        var points = joints()
        for name in [VNHumanBodyPoseObservation.JointName.leftShoulder, .rightShoulder, .leftElbow, .rightElbow, .leftWrist, .rightWrist] {
            let key = name.rawValue.rawValue
            if let p = points[key] { points[key] = CGPoint(x: p.x - 0.12, y: p.y) }
        }
        for mirrored in [false, true] {
            var comparator = ReferenceLocalComparator()
            let values = points.mapValues { LivePoseJoint(point: CGPoint(x: mirrored ? 1 - $0.x : $0.x, y: $0.y), confidence: 1) }
            let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: box, joints: values,
                subjectCount: 1, geometry: ReferenceGeometry(isMirrored: mirrored))
            let result = comparator.compare(reference: reference(joints()), live: frame)
            #expect(result.action?.direction == (mirrored ? "lean_image_left" : "lean_image_right"))
        }
    }

    @Test func bendAndStraightenElbowAndKnee() {
        for (joint, point, part) in [
            (VNHumanBodyPoseObservation.JointName.leftWrist, CGPoint(x: 0.45, y: 0.55), "left_elbow"),
            (.rightWrist, CGPoint(x: 0.55, y: 0.55), "right_elbow"),
            (.leftAnkle, CGPoint(x: 0.62, y: 0.28), "left_knee"),
            (.rightAnkle, CGPoint(x: 0.38, y: 0.28), "right_knee")
        ] {
            var bent = joints()
            bent[joint.rawValue.rawValue] = point
            for mirrored in [false, true] {
                for reverse in [false, true] {
                    let target = reverse ? joints() : bent
                    let actual = reverse ? bent : joints()
                    let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: box,
                        joints: actual.mapValues { LivePoseJoint(point: CGPoint(x: mirrored ? 1 - $0.x : $0.x, y: $0.y), confidence: 1) },
                        subjectCount: 1, geometry: ReferenceGeometry(isMirrored: mirrored))
                    var comparator = ReferenceLocalComparator()
                    let result = comparator.compare(reference: reference(target), live: frame)
                    #expect(result.action?.direction == "\(reverse ? "straighten" : "bend")_\(part)")
                    #expect(result.action?.actor == .subject)
                }
            }
        }
    }

    @Test func horizontalArmPlacementAndStance() {
        for (part, direction) in [("arm", "move_left_arm_out"), ("stance", "widen_stance")] {
            var target = joints()
            let names: [VNHumanBodyPoseObservation.JointName] = part == "arm" ? [.leftElbow, .leftWrist] : [.leftKnee, .leftAnkle]
            for name in names {
                let key = name.rawValue.rawValue
                target[key]!.x -= 0.12
            }
            var comparator = ReferenceLocalComparator()
            #expect(comparator.compare(reference: reference(target), live: live(joints())).action?.direction == direction)
            comparator.reset()
            #expect(comparator.compare(reference: reference(joints()), live: live(target)).action?.direction == (part == "arm" ? "move_left_arm_in" : "narrow_stance"))
        }
    }

    @Test func unreliableBendJointSuppressesCorrection() {
        var target = joints()
        target[VNHumanBodyPoseObservation.JointName.leftWrist.rawValue.rawValue] = CGPoint(x: 0.45, y: 0.55)
        var values = joints().mapValues { LivePoseJoint(point: $0, confidence: 1) }
        values[VNHumanBodyPoseObservation.JointName.leftElbow.rawValue.rawValue] = LivePoseJoint(point: CGPoint(x: 0.3, y: 0.55), confidence: 0.2)
        var comparator = ReferenceLocalComparator()
        let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: box, joints: values, subjectCount: 1)
        let result = comparator.compare(reference: reference(target), live: frame)
        #expect(result.poseAligned == nil)
        #expect(result.action == nil)
    }

    @Test func nonfiniteCriticalJointConfidenceIsUnknown() {
        var values = joints().mapValues { LivePoseJoint(point: $0, confidence: 1) }
        values[VNHumanBodyPoseObservation.JointName.leftElbow.rawValue.rawValue] = LivePoseJoint(point: CGPoint(x: 0.3, y: 0.55), confidence: .infinity)
        var comparator = ReferenceLocalComparator()
        let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: box, joints: values, subjectCount: 1)
        #expect(comparator.compare(reference: reference(joints()), live: frame).poseAligned == nil)
    }

    @Test func differentTrackingBackendsKeepFramingButCannotComparePose() {
        var comparator = ReferenceLocalComparator()
        let frame = LivePoseObservation(capturedAt: 10, geometryRevision: 1, personBox: box,
            joints: joints().mapValues { LivePoseJoint(point: $0, confidence: 1) }, subjectCount: 1,
            trackingBackend: .mediaPipe)
        let result = comparator.compare(reference: reference(joints()), live: frame)
        #expect(result.framingAligned)
        #expect(result.poseAligned == nil)
        #expect(result.action == nil)
    }

    @Test func measuredElbowCorrectionReachesLocalOnlyCaption() {
        var target = joints()
        target[VNHumanBodyPoseObservation.JointName.leftWrist.rawValue.rawValue] = CGPoint(x: 0.45, y: 0.55)
        var comparator = ReferenceLocalComparator()
        let evidence = comparator.compare(reference: reference(target), live: live(joints()))
        var coordinator = ReferenceCoachingCoordinator()
        let input = ReferenceCoachingInput(sessionID: UUID(), generation: 1, geometryRevision: 1, now: 10,
            local: evidence, profile: nil, comparison: nil, cloudAvailability: .localOnly, captureSafe: true)
        let result = coordinator.update(input)
        #expect(result.caption == "Ask them to bend their left elbow more")
        #expect(result.action?.actor == .subject)
        #expect(!result.referenceMatched)
        #expect(!result.allowsAutoCapture)
    }

}
