import Foundation
import Testing
import Vision
@testable import PicPal

struct PoseDetailComparatorTests {
    func measurement(_ key: PoseDetailKey, _ values: [Double], confidence: Float = 0.9) -> PoseDetailMeasurement {
        .init(key: key, values: values, confidence: confidence, observedAt: 1, unavailableReason: nil)
    }
    @Test func selectionExcludesUnrelatedTargets() {
        let profile = PoseTargetCompiler.compile(measurements: [measurement(.headTilt, [0.5]), measurement(.handPosition, [0, 1])], selected: [.headTilt])
        let cues = PoseDetailComparator.compare(profile: profile, live: [measurement(.headTilt, [0]), measurement(.handPosition, [0, 0])])
        #expect(cues.map(\.key) == [.headTilt])
    }
    @Test func unavailableAndNonfiniteNeverAlign() {
        let profile = PoseTargetCompiler.compile(measurements: [measurement(.headTilt, [.nan]), measurement(.fingerSpread, [1], confidence: 0.1)], selected: Set(PoseDetailKey.allCases))
        #expect(profile.targets.isEmpty)
    }
    @Test func spreadDirectionAndRankFollowNormalizedError() {
        let profile = PoseTargetCompiler.compile(measurements: [measurement(.headTilt, [0.2]), measurement(.fingerSpread, [2])], selected: Set(PoseDetailKey.allCases))
        let cues = PoseDetailComparator.compare(profile: profile, live: [measurement(.headTilt, [0]), measurement(.fingerSpread, [0.5])])
        #expect(cues.first?.key == .fingerSpread)
        #expect(cues.first?.action.instruction == "Spread your index and middle fingers slightly")
        let narrow = PoseDetailComparator.compare(profile: profile, live: [measurement(.fingerSpread, [3])])
        #expect(narrow.first?.action.instruction == "Bring your index and middle fingers slightly closer together")
    }
    @Test func anglesWrapAndMissingLiveIsUnknown() {
        let profile = PoseTargetCompiler.compile(measurements: [measurement(.headTilt, [Double.pi - 0.03])], selected: [.headTilt])
        #expect(PoseDetailComparator.compare(profile: profile, live: [measurement(.headTilt, [-Double.pi + 0.03])]).isEmpty)
        #expect(PoseDetailComparator.alignedDetails(profile: profile, live: []).isEmpty)
    }
}

extension PoseDetailComparatorTests {
    @Test func missingWristPreservesSpreadAndPlacement() {
        let joints: [String: LivePoseJoint] = [
            VNHumanHandPoseObservation.JointName.indexMCP.rawValue.rawValue: .init(point: CGPoint(x: 0.4, y: 0.4), confidence: 0.9),
            VNHumanHandPoseObservation.JointName.middleMCP.rawValue.rawValue: .init(point: CGPoint(x: 0.45, y: 0.4), confidence: 0.9),
            VNHumanHandPoseObservation.JointName.littleMCP.rawValue.rawValue: .init(point: CGPoint(x: 0.55, y: 0.4), confidence: 0.9),
            VNHumanHandPoseObservation.JointName.indexTip.rawValue.rawValue: .init(point: CGPoint(x: 0.35, y: 0.7), confidence: 0.9),
            VNHumanHandPoseObservation.JointName.middleTip.rawValue.rawValue: .init(point: CGPoint(x: 0.55, y: 0.7), confidence: 0.9)
        ]
        let hand = SelfiePoseTracker.adapt(joints, imageAspectRatio: 1)
        #expect(hand != nil)
        #expect(hand?.roll == nil)
        #expect(hand?.fingerSpread != nil)
        #expect(hand?.victory == nil)
    }
    @Test func ambiguousHandsDoNotEraseHeadEvidence() {
        let values = PoseDetailMeasurement.measure(selfie: .init(roll: 0.3,
            hands: [.init(anchor: CGPoint(x: 0.3, y: 0.5), victory: nil)], handsAvailable: true, detectedHandCount: 2),
            face: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), joints: [:], geometry: .init(), at: 1)
        #expect(values.first { $0.key == .headTilt }?.isAvailable == true)
        #expect(values.first { $0.key == .handPosition }?.isAvailable == false)
    }
    @Test func lowConfidenceAndNonfiniteAnchorAreUnknown() {
        for hand in [SelfieHandObservation(anchor: CGPoint(x: 0.3, y: 0.5), victory: nil, confidence: 0.1),
                     SelfieHandObservation(anchor: CGPoint(x: Double.nan, y: 0.5), victory: nil)] {
            let values = PoseDetailMeasurement.measure(selfie: .init(hands: [hand], handsAvailable: true),
                face: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), joints: [:], geometry: .init(), at: 1)
            #expect(values.first { $0.key == .handPosition }?.isAvailable == false)
        }
    }
}

extension PoseDetailComparatorTests {
    @Test func handPositionIsTranslationAndScaleInvariant() {
        func position(face: CGRect, hand: CGPoint) -> PoseDetailMeasurement {
            PoseDetailMeasurement.measure(selfie: .init(hands: [.init(anchor: hand, victory: nil)], handsAvailable: true),
                face: face, joints: [:], geometry: .init(), at: 1).first { $0.key == .handPosition }!
        }
        let original = position(face: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), hand: CGPoint(x: 0.35, y: 0.55))
        let scaled = position(face: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4), hand: CGPoint(x: 0.2, y: 0.5))
        let profile = PoseTargetCompiler.compile(measurements: [original], selected: [.handPosition])
        #expect(PoseDetailComparator.alignedDetails(profile: profile, live: [scaled]) == [.handPosition])
    }
    @Test func shoulderTiltRequiresTwoReliableShouldersAndUsesAspectRatio() {
        let left = VNHumanBodyPoseObservation.JointName.leftShoulder.rawValue.rawValue
        let right = VNHumanBodyPoseObservation.JointName.rightShoulder.rawValue.rawValue
        let joints: [String: LivePoseJoint] = [left: .init(point: CGPoint(x: 0.3, y: 0.4), confidence: 0.9),
                                              right: .init(point: CGPoint(x: 0.6, y: 0.6), confidence: 0.8)]
        let full = PoseDetailMeasurement.measure(selfie: nil, face: nil, joints: joints, geometry: .init(imageAspectRatio: 2), at: 1)
        let angle = full.first { $0.key == .shoulderTilt }!
        #expect(abs(angle.values[0] - atan2(0.2, 0.6)) < 0.00001)
        let partial = PoseDetailMeasurement.measure(selfie: nil, face: nil, joints: [left: joints[left]!], geometry: .init(), at: 1)
        #expect(partial.first { $0.key == .shoulderTilt }?.isAvailable == false)
    }
    @Test func matchingPartialDetailsNeverCertifiesCaptureWithDifferentFraming() {
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let reference = ReferencePose(bodyKeypoints: [:], faceCenter: nil, faceYaw: nil, subjectBoundingBox: face,
            subjectCenterX: 0.5, subjectCenterY: 0.5, subjectHeightFraction: 0.2, headroomFraction: 0.4,
            faceBox: face, framingDomain: .face, selfie: .init(roll: 0.2))
        let live = LivePoseObservation(capturedAt: 1, geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1,
            faceBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4), selfie: .init(roll: 0.2))
        var comparator = ReferenceLocalComparator()
        let evidence = comparator.compare(reference: reference, live: live, selfieAtMinimumZoom: true, selected: [.headTilt])
        #expect(!evidence.framingAligned)
        #expect(evidence.poseAligned == nil)
        #expect(evidence.alignedPoseDetails == ["selfie_head_tilt"])
        var coordinator = ReferenceCoachingCoordinator()
        let output = coordinator.update(.init(sessionID: UUID(), generation: 1, geometryRevision: 1, now: 1,
            local: evidence, cloudAvailability: .localOnly, captureSafe: true))
        #expect(!output.allowsAutoCapture)
    }
}


extension PoseDetailComparatorTests {
    @Test(arguments: [Float(0.56), Float(0.49)])
    func localHandQualityUsesLandmarkFloorWithoutInflation(confidence: Float) {
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let reference = ReferencePose(bodyKeypoints: [:], faceCenter: nil, faceYaw: nil, subjectBoundingBox: face,
            subjectCenterX: 0.5, subjectCenterY: 0.5, subjectHeightFraction: 0.2, headroomFraction: 0.4,
            faceBox: face, framingDomain: .face,
            selfie: .init(hands: [.init(anchor: CGPoint(x: 0.35, y: 0.55), victory: nil, confidence: confidence)], handsAvailable: true))
        let live = LivePoseObservation(capturedAt: 1, geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1,
            faceBox: face, selfie: .init(hands: [.init(anchor: CGPoint(x: 0.35, y: 0.4), victory: nil, confidence: confidence)], handsAvailable: true))
        var comparator = ReferenceLocalComparator()
        let evidence = comparator.compare(reference: reference, live: live, selected: [.handPosition])
        var coordinator = ReferenceCoachingCoordinator()
        let output = coordinator.update(.init(sessionID: UUID(), generation: 1, geometryRevision: 1, now: 1,
            local: evidence, cloudAvailability: .localOnly, captureSafe: true))
        if confidence >= 0.5 {
            #expect(output.action?.direction == "selfie_hand_position")
            #expect(output.action?.confidence == Double(confidence))
        } else { #expect(output.action == nil) }
        #expect(!output.allowsAutoCapture)
    }
}

extension PoseDetailComparatorTests {
    private func rankedCandidate(_ key: PoseDetailKey, error: Double) -> PoseDetailCandidate {
        .init(key: key, normalizedError: error, confidence: 0.9,
            action: .init(id: key.evidenceKey + "_left", dimension: .pose, actor: .subject,
                          direction: key.evidenceKey, instruction: "Adjust \(key.rawValue)",
                          expectedChange: "Reduce measured error", confidence: 0.9), target: nil)
    }
    @Test func activeDetailSurvivesSmallRankChangesAndRequiresStableMaterialReplacement() {
        var coordinator = ReferenceCoachingCoordinator()
        let session = UUID()
        let current = rankedCandidate(.handPosition, error: 2)
        let dimension = ReferenceDimensionComparison(dimension: .pose, status: .different,
            referenceEvidence: "Visible reference details", liveEvidence: "Visible live details", confidence: 0.9)
        for (time, competingError, expected) in [(1.0, 1.0, PoseDetailKey.handPosition),
                                                (1.2, 2.2, .handPosition),
                                                (1.4, 3.0, .handPosition),
                                                (1.6, 3.0, .headTilt)] {
            let competing = rankedCandidate(.headTilt, error: competingError)
            let ranked = competingError > 2 ? [competing, current] : [current, competing]
            let evidence = LocalReferenceEvidence(capturedAt: time, geometryRevision: 1, framingAligned: true,
                poseAligned: nil, dimensions: [dimension], action: ranked[0].action,
                subjectPresent: true, analysisAvailable: true, subjectCount: 1,
                availablePoseDetails: [PoseDetailKey.handPosition.evidenceKey, PoseDetailKey.headTilt.evidenceKey],
                poseCandidates: ranked)
            let output = coordinator.update(.init(sessionID: session, generation: 1, geometryRevision: 1, now: time,
                local: evidence, cloudAvailability: .localOnly, captureSafe: true))
            #expect(output.action?.direction == expected.evidenceKey)
        }
    }
    @Test func explicitFocusSuppressesUnscopedCloudPoseAction() {
        var coordinator = ReferenceCoachingCoordinator()
        let session = UUID()
        let dimension = ReferenceDimensionComparison(dimension: .pose, status: .different,
            referenceEvidence: "Arm raised", liveEvidence: "Arm lowered", confidence: 0.9)
        let action = ReferenceAction(id: "cloud_arm", dimension: .pose, actor: .subject, direction: "raise_arm",
            instruction: "Raise your arm", expectedChange: "Arm matches", confidence: 0.9)
        let evidence = LocalReferenceEvidence(capturedAt: 1, geometryRevision: 1, framingAligned: true,
            poseAligned: nil, dimensions: [dimension], action: nil, subjectPresent: true, analysisAvailable: true,
            subjectCount: 1, selectedPoseDetails: [.headTilt])
        let comparison = ReferenceComparison(schemaVersion: 1, dimensions: [dimension], action: action)
        let envelope = ReferenceEnvelope(sessionID: session, generation: 1, requestID: UUID(), capturedAt: 1, geometryRevision: 1)
        let output = coordinator.update(.init(sessionID: session, generation: 1, geometryRevision: 1, now: 1,
            local: evidence, comparison: (envelope: envelope, value: comparison), cloudAvailability: .available, captureSafe: true))
        #expect(output.action == nil)
        #expect(!output.allowsAutoCapture)
    }
}
