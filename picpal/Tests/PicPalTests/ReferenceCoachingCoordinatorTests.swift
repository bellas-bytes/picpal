import Foundation
import Testing
@testable import PicPal

struct ReferenceCoachingCoordinatorTests {
    private let session = UUID()

    private func action(_ dimension: ReferenceDimension = .lighting, direction: String = "toward-window") -> ReferenceAction {
        ReferenceAction(id: "model-id", dimension: dimension, actor: .photographer, direction: direction,
                        instruction: "Move toward the window", expectedChange: "Softer side light", confidence: 0.9)
    }

    private func input(_ time: Double, difference: ReferenceDimension? = nil, safe: Bool = true,
                       cloud: ReferenceCloudAvailability = .available, stamp: Double? = nil,
                       pose: Bool? = true, proposal: ReferenceAction? = nil) -> ReferenceCoachingInput {
        let envelope = ReferenceEnvelope(sessionID: session, generation: 1, requestID: UUID(),
                                         capturedAt: stamp ?? time, geometryRevision: 1)
        let dimensions = ReferenceDimension.allCases.map {
            ReferenceDimensionComparison(dimension: $0, status: $0 == difference ? .different : .matched,
                                         referenceEvidence: "Visible reference evidence", liveEvidence: "Visible live evidence", confidence: 0.9)
        }
        return ReferenceCoachingInput(sessionID: session, generation: 1, geometryRevision: 1, now: time,
            local: LocalReferenceEvidence(capturedAt: time, geometryRevision: 1, framingAligned: true,
                poseAligned: pose, dimensions: dimensions.filter { $0.dimension == .framing || $0.dimension == .pose },
                action: nil, subjectPresent: true, analysisAvailable: true, subjectCount: 1),
            profile: (envelope, ReferenceProfile(schemaVersion: 1, summary: "Portrait", features: ReferenceDimension.allCases.map {
                ReferenceFeature(dimension: $0, evidence: "Visible feature", confidence: 0.9, applicable: true)
            })), comparison: (envelope, ReferenceComparison(schemaVersion: 1, dimensions: dimensions,
                                                          action: proposal ?? difference.map { action($0) })),
            cloudAvailability: cloud, captureSafe: safe)
    }

    @Test func unsafeCaptureKeepsCorrection() {
        var coordinator = ReferenceCoachingCoordinator()
        let result = coordinator.update(input(10, difference: .lighting, safe: false))
        #expect(result.action?.dimension == .lighting)
        #expect(!result.allowsAutoCapture)
    }

    @Test func sameRectangleWrongPoseNeverMatches() {
        var coordinator = ReferenceCoachingCoordinator()
        for time in stride(from: 10.0, through: 12.0, by: 0.5) {
            let result = coordinator.update(input(time, difference: .pose, pose: false))
            #expect(!result.referenceMatched)
        }
    }

    @Test func localOnlyNeverClaimsOverallMatch() {
        var coordinator = ReferenceCoachingCoordinator()
        let result = coordinator.update(input(10, cloud: .localOnly))
        #expect(result.phase == .localOnly)
        #expect(result.caption == "Measured pose and framing aligned")
        #expect(!result.referenceMatched)
    }

    @Test func fullMatchRequiresContinuousFreshLocalDwell() {
        var coordinator = ReferenceCoachingCoordinator()
        #expect(!coordinator.update(input(10)).referenceMatched)
        #expect(!coordinator.update(input(10.5)).referenceMatched)
        #expect(!coordinator.update(input(11)).referenceMatched)
        let result = coordinator.update(input(11.5))
        #expect(result.referenceMatched)
        #expect(result.allowsAutoCapture)
    }

    @Test func gapsAndUnknownPoseResetDwell() {
        var coordinator = ReferenceCoachingCoordinator()
        _ = coordinator.update(input(10))
        #expect(!coordinator.update(input(12)).referenceMatched)
        #expect(!coordinator.update(input(12.5, pose: nil)).referenceMatched)
        #expect(!coordinator.update(input(13)).referenceMatched)
    }

    @Test func expiredComparisonCannotRemainActionOrMatch() {
        var coordinator = ReferenceCoachingCoordinator()
        _ = coordinator.update(input(10, difference: .lighting))
        let result = coordinator.update(input(19, difference: .lighting, stamp: 10))
        #expect(result.action == nil)
        #expect(result.phase == .verifying)
        #expect(!result.referenceMatched)
    }

    @Test func identityMismatchRejected() {
        var coordinator = ReferenceCoachingCoordinator()
        var value = input(10, difference: .lighting)
        value.generation = 2
        #expect(coordinator.update(value).action == nil)
        value = input(10, difference: .lighting)
        value.geometryRevision = 2
        #expect(coordinator.update(value).action == nil)
    }

    @Test func unsupportedSubjectsClearGuidance() {
        var coordinator = ReferenceCoachingCoordinator()
        var value = input(10, difference: .lighting)
        value.local = LocalReferenceEvidence(capturedAt: 10, geometryRevision: 1, framingAligned: true,
            poseAligned: true, dimensions: [], action: nil, subjectPresent: true, analysisAvailable: true, subjectCount: 2)
        let result = coordinator.update(value)
        #expect(result.phase == .unsupported)
        #expect(result.action == nil)
    }

    @Test func matchedActiveDimensionRecognizesImprovement() {
        var coordinator = ReferenceCoachingCoordinator()
        _ = coordinator.update(input(10, difference: .lighting))
        let result = coordinator.update(input(10.5))
        #expect(result.explanation == "Lighting now aligns with the reference.")
        #expect(!result.referenceMatched)
    }

    @Test func reversalRequiresRepeatedNewEvidence() {
        var coordinator = ReferenceCoachingCoordinator()
        _ = coordinator.update(input(10, difference: .lighting))
        let reverse = action(direction: "away-from-window")
        #expect(coordinator.update(input(10.2, difference: .lighting, proposal: reverse)).action?.direction == "toward-window")
        #expect(coordinator.update(input(10.4, difference: .lighting, proposal: reverse)).action?.direction == "away-from-window")
    }
    @Test func replayedFrameCannotAccumulateDwell() {
        var coordinator = ReferenceCoachingCoordinator()
        var value = input(10)
        _ = coordinator.update(value)
        value.now = 10.5
        #expect(!coordinator.update(value).referenceMatched)
        value.now = 12
        #expect(!coordinator.update(value).referenceMatched)
    }

    @Test func unknownOrLowConfidenceCloudEvidenceBlocksMatch() {
        for status in [DimensionStatus.unknown, .matched] {
            var coordinator = ReferenceCoachingCoordinator()
            for time in stride(from: 10.0, through: 12.0, by: 0.5) {
                var value = input(time)
                let original = value.comparison!
                let dimensions = original.value.dimensions.map { dimension in
                    dimension.dimension == .viewpoint ? ReferenceDimensionComparison(dimension: .viewpoint,
                        status: status, referenceEvidence: "Reference", liveEvidence: "Live",
                        confidence: status == .matched ? 0.2 : 0.9) : dimension
                }
                value.comparison = (original.envelope, ReferenceComparison(schemaVersion: 1, dimensions: dimensions, action: nil))
                #expect(!coordinator.update(value).referenceMatched)
            }
        }
    }

    @Test func directFramingCorrectionOverridesInferredDirection() {
        var coordinator = ReferenceCoachingCoordinator()
        var value = input(10, difference: .framing)
        // Initially only cloud has an assessable framing comparison.
        value.local = LocalReferenceEvidence(capturedAt: 10, geometryRevision: 1, framingAligned: false,
            poseAligned: true, dimensions: [], action: nil, subjectPresent: true, analysisAvailable: true, subjectCount: 1)
        _ = coordinator.update(value)
        value = input(10.1, difference: .framing)
        let correction = action(.framing, direction: "camera-right")
        value.local = LocalReferenceEvidence(capturedAt: 10.1, geometryRevision: 1, framingAligned: false,
            poseAligned: true, dimensions: value.local!.dimensions, action: correction,
            subjectPresent: true, analysisAvailable: true, subjectCount: 1)
        #expect(coordinator.update(value).action?.direction == "camera-right")
    }

    @Test func sameEvidenceCannotConfirmReversal() {
        var coordinator = ReferenceCoachingCoordinator()
        _ = coordinator.update(input(10, difference: .lighting))
        let reverse = input(10.2, difference: .lighting, proposal: action(direction: "away-from-window"))
        _ = coordinator.update(reverse)
        #expect(coordinator.update(reverse).action?.direction == "toward-window")
    }

    @Test func locallyAlignedLimbsDoNotEraseCloudHeadTurn() {
        var coordinator = ReferenceCoachingCoordinator()
        let headTurn = ReferenceAction(id: "head", dimension: .pose, actor: .subject,
            direction: "head-left", instruction: "Turn your head left", expectedChange: "Match the face direction", confidence: 0.9)
        for time in [10.0, 10.5] {
            var value = input(time, difference: .pose, proposal: headTurn)
            value.local = input(time).local
            let result = coordinator.update(value)
            #expect(result.action?.direction == "head-left")
            #expect(result.explanation != "Pose now aligns with the reference.")
            #expect(!result.referenceMatched)
        }
    }

    @Test func unknownCloudPoseCannotBePraisedFromLocalLimbMatch() {
        var coordinator = ReferenceCoachingCoordinator()
        _ = coordinator.update(input(10, difference: .pose))
        var value = input(10.5)
        let original = value.comparison!
        let dimensions = original.value.dimensions.map { dimension in
            dimension.dimension == .pose ? ReferenceDimensionComparison(dimension: .pose, status: .unknown,
                referenceEvidence: "Face direction", liveEvidence: "Face obscured", confidence: 0.9) : dimension
        }
        value.comparison = (original.envelope, ReferenceComparison(schemaVersion: 1, dimensions: dimensions, action: nil))
        let result = coordinator.update(value)
        #expect(result.action == nil)
        #expect(result.explanation != "Pose now aligns with the reference.")
        #expect(!result.referenceMatched)
    }

    @Test func cloudPoseProgressUsesCloudFrameTime() {
        var coordinator = ReferenceCoachingCoordinator()
        _ = coordinator.update(input(10, difference: .pose))
        var value = input(10.5, stamp: 9.5)
        value.local = input(10.5).local
        let result = coordinator.update(value)
        #expect(result.explanation != "Pose now aligns with the reference.")
        #expect(!result.referenceMatched)
    }

    @Test func localPoseDifferenceBlocksCloudMatchAndOffersCorrection() {
        var coordinator = ReferenceCoachingCoordinator()
        var value = input(10)
        let localDifference = input(10, difference: .pose, pose: false).local!
        value.local = LocalReferenceEvidence(capturedAt: 10, geometryRevision: 1, framingAligned: true,
            poseAligned: false, dimensions: localDifference.dimensions, action: action(.pose, direction: "raise-arm"),
            subjectPresent: true, analysisAvailable: true, subjectCount: 1)
        let result = coordinator.update(value)
        #expect(result.action?.direction == "raise-arm")
        #expect(!result.referenceMatched)
        #expect(!result.allowsAutoCapture)
    }

    @Test func localOnlyDescribesUnknownAndUnsupportedDifferences() {
        for pose in [Bool?.none, false] {
            var coordinator = ReferenceCoachingCoordinator()
            let result = coordinator.update(input(10, difference: pose == false ? .pose : nil, cloud: .localOnly, pose: pose))
            #expect(result.caption == (pose == nil ? "Show the full pose clearly" : "Pose differs from the reference"))
            #expect(!result.referenceMatched)
            #expect(!result.allowsAutoCapture)
        }
    }

}
