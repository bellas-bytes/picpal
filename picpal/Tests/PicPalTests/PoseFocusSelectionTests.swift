import Testing
import UIKit
@testable import PicPal

@MainActor
struct PoseFocusSelectionTests {
    @Test func focusGroupsKeepUnknownDetailsSelected() {
        let session = ReferenceSession(image: UIImage())
        #expect(session.selectedPoseDetails == Set(PoseDetailKey.allCases))
        #expect(session.setPoseFocus(.hand))
        #expect(session.selectedPoseDetails == [.handPosition, .fingerSpread, .handRoll])
        #expect(!session.setPoseFocus(.hand))
        #expect(session.setPoseFocus(.head))
        #expect(session.selectedPoseDetails == [.headTilt, .headTurn])
        #expect(session.setPoseFocus(.all))
        #expect(session.selectedPoseDetails == Set(PoseDetailKey.allCases))
    }

    @Test func focusChangeClearsCoachingWithoutChangingGeometry() {
        let model = CameraScreenModel()
        let session = ReferenceSession(image: UIImage())
        model.configureReference(session, cloudAllowed: true)
        let revision = model.referenceGeometryRevision
        let generation = model.referenceGeneration
        model.toggleAutoCapture()
        model.referenceFocusDidChange()
        #expect(model.referenceGeometryRevision == revision)
        #expect(model.referenceGeneration == generation + 1)
        #expect(model.referenceDecision == nil)
        #expect(model.referenceComparison == nil)
        #expect(!model.isArmed)
    }

    @Test func focusChangeRejectsOldCloudResult() {
        let model = CameraScreenModel()
        let session = ReferenceSession(image: UIImage())
        model.configureReference(session, cloudAllowed: true)
        let old = ReferenceEnvelope(sessionID: session.id, generation: model.referenceGeneration,
            requestID: UUID(), capturedAt: Date().timeIntervalSince1970, geometryRevision: model.referenceGeometryRevision)
        let comparison = ReferenceComparison(schemaVersion: 1, dimensions: [], action: nil)
        model.receive(referenceAnalysis: .comparison(old, comparison))
        #expect(model.referenceComparison != nil)
        model.referenceFocusDidChange()
        model.receive(referenceAnalysis: .comparison(old, comparison))
        #expect(model.referenceComparison == nil)
    }

    @Test func freshReferenceStartsWithAllVisibleFocus() {
        let old = ReferenceSession(image: UIImage())
        old.setPoseFocus(.head)
        let replacement = ReferenceSession(image: UIImage())
        #expect(replacement.poseFocus == .all)
        #expect(replacement.selectedPoseDetails == Set(PoseDetailKey.allCases))
    }
}
