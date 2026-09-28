import Foundation
import Testing
import Vision
@testable import PicPal

/// Numeric pose pairs evaluate behavior independently of detector confidence or image assets.
struct SelfiePoseEvaluationTests {
    private let face = CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.3)

    private func hand(openPalm: Bool = false) -> [String: LivePoseJoint] {
        typealias J = VNHumanHandPoseObservation.JointName
        let points: [(J, CGPoint)] = [
            (.wrist, .init(x: 0.5, y: 0.2)),
            (.indexMCP, .init(x: 0.45, y: 0.4)), (.indexPIP, .init(x: 0.43, y: 0.55)), (.indexTip, .init(x: 0.4, y: 0.75)),
            (.middleMCP, .init(x: 0.55, y: 0.4)), (.middlePIP, .init(x: 0.57, y: 0.55)), (.middleTip, .init(x: 0.6, y: 0.75)),
            (.ringMCP, .init(x: 0.60, y: 0.4)), (.ringPIP, .init(x: 0.62, y: 0.5)),
            (.ringTip, .init(x: openPalm ? 0.66 : 0.61, y: openPalm ? 0.7 : 0.35)),
            (.littleMCP, .init(x: 0.65, y: 0.38)), (.littlePIP, .init(x: 0.68, y: 0.46)),
            (.littleTip, .init(x: openPalm ? 0.74 : 0.66, y: openPalm ? 0.62 : 0.32))
        ]
        return Dictionary(uniqueKeysWithValues: points.map { ($0.0.rawValue.rawValue, LivePoseJoint(point: $0.1, confidence: 0.9)) })
    }

    @Test func visibleVictoryAndOpenPalmAreDifferentButOcclusionIsUnknown() {
        #expect(SelfiePoseTracker.victory(hand()) == true)
        #expect(SelfiePoseTracker.victory(hand(openPalm: true)) == false)
        var occluded = hand()
        occluded.removeValue(forKey: VNHumanHandPoseObservation.JointName.ringTip.rawValue.rawValue)
        #expect(SelfiePoseTracker.victory(occluded) == nil)
    }

    @Test(arguments: [0.75, 4.0 / 3.0])
    func gestureClassificationUsesPhysicalAspectRatio(aspect: Double) {
        let encoded = hand().mapValues { joint in
            LivePoseJoint(point: CGPoint(x: 0.5 + (joint.point.x - 0.5) / aspect, y: joint.point.y), confidence: joint.confidence)
        }
        #expect(SelfiePoseTracker.victory(encoded, imageAspectRatio: aspect) == true)
    }

    private func reference(face: CGRect, anchor: CGPoint, geometry: ReferenceGeometry = .init()) -> ReferencePose {
        ReferencePose(bodyKeypoints: [:], faceCenter: CGPoint(x: face.midX, y: face.midY), faceYaw: nil,
            subjectBoundingBox: face, subjectCenterX: Float(face.midX), subjectCenterY: Float(face.midY),
            subjectHeightFraction: Float(face.height), headroomFraction: Float(1 - face.maxY),
            geometry: geometry, faceBox: face, framingDomain: .face,
            selfie: SelfiePoseObservation(hands: [.init(anchor: anchor, victory: nil)], handsAvailable: true))
    }

    private func live(face: CGRect, anchor: CGPoint, geometry: ReferenceGeometry = .init(), time: Double = 1) -> LivePoseObservation {
        LivePoseObservation(capturedAt: time, geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1,
            geometry: geometry, faceBox: face,
            selfie: SelfiePoseObservation(hands: [.init(anchor: anchor, victory: nil)], handsAvailable: true))
    }

    @Test func zoomAndTranslationDoNotInventHandMovement() {
        let ref = reference(face: face, anchor: CGPoint(x: 0.35, y: 0.525))
        let largerFace = CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6)
        let observed = live(face: largerFace, anchor: CGPoint(x: 0.2, y: 0.35))
        let result = SelfiePoseComparator.compare(reference: ref, live: observed)
        #expect(result.action == nil)
        #expect(result.alignedDetails.contains("selfie_hand_position"))
    }

    @Test(arguments: [false, true])
    func horizontalCueUsesDisplayedSideForEitherCamera(mirrored: Bool) {
        let geometry = ReferenceGeometry(imageAspectRatio: 4.0 / 3.0, isMirrored: mirrored)
        let ref = reference(face: face, anchor: CGPoint(x: 0.35, y: 0.525))
        let observed = live(face: face, anchor: CGPoint(x: 0.6, y: 0.525), geometry: geometry)
        let result = SelfiePoseComparator.compare(reference: ref, live: observed)
        #expect(result.action?.instruction == "Move your hand toward the left side of the preview")
        #expect(abs((result.target?.point.x ?? -1) - 0.35) < 0.000001)
        #expect(abs((result.target?.point.y ?? -1) - 0.475) < 0.000001)
    }

    @Test func markerUsesPreviewCropAndTopLeftOrigin() {
        let geometry = ReferenceGeometry(imageAspectRatio: 1.5, viewportAspectRatio: 0.75)
        let result = SelfiePoseComparator.compare(
            reference: reference(face: face, anchor: CGPoint(x: 0.45, y: 0.525)),
            live: live(face: face, anchor: CGPoint(x: 0.6, y: 0.525), geometry: geometry))
        #expect(abs((result.target?.point.x ?? -1) - 0.4) < 0.000001)
        #expect(abs((result.target?.point.y ?? -1) - 0.475) < 0.000001)
    }

    @Test func partialDetailSuccessNeverEnablesAutomaticCapture() {
        let ref = reference(face: face, anchor: CGPoint(x: 0.35, y: 0.525))
        var comparator = ReferenceLocalComparator()
        var coordinator = ReferenceCoachingCoordinator()
        let session = UUID()
        for time in [1.0, 1.4, 2.0, 3.0] {
            let local = comparator.compare(reference: ref,
                live: live(face: face, anchor: CGPoint(x: 0.35, y: 0.525), time: time))
            let result = coordinator.update(.init(sessionID: session, generation: 1, geometryRevision: 1,
                now: time, local: local, cloudAvailability: .localOnly, captureSafe: true))
            #expect(local.poseAligned == nil)
            #expect(!result.referenceMatched)
            #expect(!result.allowsAutoCapture)
        }
    }
}
