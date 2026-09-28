import CoreGraphics
import Foundation
import Testing
@testable import PicPal

struct PersonShotCoachTests {
    private let goodBox = CGRect(x: 0.35, y: 0.15, width: 0.3, height: 0.7)
    private func assess(_ box: CGRect?, style: ShotStyle = .fullBody,
                        time: TimeInterval = 10, available: Bool = true,
                        settled: Bool = true, exposure: Bool = true,
                        tilt: TiltSignal? = TiltSignal(angleDegrees: 0, isLevel: true)) -> ShotAssessment {
        PersonShotCoach.assess(observation: SubjectObservation(box: box, confidence: 0.95,
            observedAt: time, analysisAvailable: available), style: style, tilt: tilt,
            isSettled: settled, exposureOK: exposure, now: 10)
    }

    @Test func absencePrecedesTilt() {
        let result = assess(nil, tilt: TiltSignal(angleDegrees: 20, isLevel: false))
        #expect(result.message == "I can't see a person yet")
        #expect(!result.isReady && !result.allowsAutoZoom)
    }
    @Test func unavailableIsDifferentFromAbsence() {
        #expect(assess(nil, available: false).message == "Person detection is unavailable")
    }
    @Test func staleAndUnknownCannotBeReady() {
        #expect(!assess(goodBox, time: 8).isReady)
        #expect(!assess(goodBox, tilt: nil).isReady)
        #expect(!assess(goodBox, time: 11).isReady)
    }
    @Test func shotStyleChangesDistanceGuidance() {
        let box = CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.5)
        #expect(assess(box).isReady)
        #expect(assess(box, style: .portrait).message == "Move closer for a portrait")
    }
    @Test func clippingRequestsMovementWithoutZoom() {
        let result = assess(CGRect(x: 0.3, y: 0, width: 0.4, height: 0.98))
        #expect(result.message == "Step back to include head and feet")
        #expect(!result.allowsAutoZoom)
    }
    @Test func portraitAllowsIntentionalLowerCrop() {
        #expect(assess(CGRect(x: 0.2, y: 0, width: 0.6, height: 0.9), style: .portrait).isReady)
    }
    @Test func centeredAndThirdsFramingAreViable() {
        #expect(assess(goodBox).isReady)
        #expect(assess(CGRect(x: 0.2, y: 0.15, width: 0.25, height: 0.7)).isReady)
    }
    @Test func movementAndExposurePreventReadiness() {
        #expect(!assess(goodBox, settled: false).allowsAutoZoom)
        #expect(!assess(goodBox, exposure: false).isReady)
    }
    @Test func minorTiltIsTolerated() {
        #expect(assess(goodBox, tilt: TiltSignal(angleDegrees: 5, isLevel: false)).isReady)
        #expect(!assess(goodBox, tilt: TiltSignal(angleDegrees: 8, isLevel: false)).isReady)
    }
    @Test func exactWideOffCenterReferenceIsReady() {
        let box = CGRect(x: 0.02, y: 0.4, width: 0.1, height: 0.2)
        let pose = reference(box)
        let result = PersonShotCoach.assessReference(
            observation: SubjectObservation(box: box, confidence: 0.95, observedAt: 10, analysisAvailable: true),
            pose: pose, tilt: TiltSignal(angleDegrees: 0, isLevel: true),
            isSettled: true, exposureOK: true, now: 10)
        #expect(result.isReady)
        #expect(result.message == ReferenceCoach.CueText.matched)
    }

    @Test func referenceCannotMatchAbsentOrStalePerson() {
        for observation in [
            SubjectObservation(box: nil, confidence: 0, observedAt: 10, analysisAvailable: true),
            SubjectObservation(box: goodBox, confidence: 0.95, observedAt: 8, analysisAvailable: true)
        ] {
            let result = PersonShotCoach.assessReference(observation: observation, pose: reference(goodBox),
                tilt: TiltSignal(angleDegrees: 0, isLevel: true), isSettled: true, exposureOK: true, now: 10)
            #expect(!result.isReady)
            #expect(!result.allowsAutoZoom)
        }
    }

    @Test func unreadReferenceCannotBeReady() {
        let result = PersonShotCoach.assessReference(
            observation: SubjectObservation(box: goodBox, confidence: 0.95, observedAt: 10, analysisAvailable: true),
            pose: nil, tilt: TiltSignal(angleDegrees: 0, isLevel: true),
            isSettled: true, exposureOK: true, now: 10)
        #expect(!result.isReady)
        #expect(result.message == "Reading reference")
    }

    @Test func referenceMovementUsesVisionCoordinatesAndBlocksZoom() {
        let target = CGRect(x: 0.1, y: 0.15, width: 0.3, height: 0.7)
        let result = PersonShotCoach.assessReference(
            observation: SubjectObservation(box: goodBox, confidence: 0.95, observedAt: 10, analysisAvailable: true),
            pose: reference(target), tilt: TiltSignal(angleDegrees: 0, isLevel: true),
            isSettled: true, exposureOK: true, now: 10)
        #expect(result.message == ReferenceCoach.CueText.moveLeft)
        #expect(!result.isReady && !result.allowsAutoZoom)
    }

    private func reference(_ box: CGRect) -> ReferencePose {
        ReferencePose(bodyKeypoints: [:], faceCenter: nil, faceYaw: nil, subjectBoundingBox: box,
            subjectCenterX: Float(box.midX), subjectCenterY: Float(box.midY),
            subjectHeightFraction: Float(box.height), headroomFraction: Float(1 - box.maxY))
    }
}
