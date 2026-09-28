import Testing
import Vision
import UIKit
import CoreGraphics
import Combine
import os
@testable import PicPal

// MARK: - ReferenceSessionTests

/// Tests for `ReferenceSession` state transitions and error paths.
///
/// Vision inference itself is not mockable end-to-end in unit tests. All tests inject a
/// fast `@Sendable (UIImage) -> ReferencePose?` closure via the `visionExtractor` init
/// parameter, isolating `extractPose()` logic from actual Vision I/O.
///
/// Acceptance criteria covered:
///   1. `isExtracting` is `false` at init.
///   2. `pose` is `nil` at init.
///   3. `isExtracting` becomes `true` during extraction and `false` on completion.
///   4. `pose` is non-nil after a mock extractor returns a valid pose.
///   5. `pose` is `nil` after a mock extractor returns nil (no body detected).
///   6. `extractPose()` completes within 500 ms using a fast mock.
///   7. `image` is stored unchanged after init.
///   8. Repeated calls to `extractPose()` replace the previous pose value.
@Suite("ReferenceSession") @MainActor
struct ReferenceSessionTests {

    // MARK: - Helpers

    /// Returns a minimal 32 × 32 solid-gray `UIImage` suitable for unit tests.
    private func makeBlankImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32))
        return renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 32, height: 32)))
        }
    }

    /// Returns a `ReferencePose` with representative values for assertion.
    private func makeMockPose() -> ReferencePose {
        ReferencePose(
            bodyKeypoints: [
                "nose_tip": CGPoint(x: 0.5, y: 0.72),
                "left_shoulder": CGPoint(x: 0.38, y: 0.52)
            ],
            faceCenter: CGPoint(x: 0.5, y: 0.76),
            faceYaw: 0.05,
            subjectBoundingBox: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.6),
            subjectCenterX: 0.5,
            subjectCenterY: 0.5,
            subjectHeightFraction: 0.6,
            headroomFraction: 0.2
        )
    }

    // MARK: - Initial state

    @Test("isExtracting is false at init")
    func isExtractingFalseAtInit() {
        let session = ReferenceSession(image: makeBlankImage()) { _ in throw ReferenceSessionError.noPoseDetected }
        #expect(!session.isExtracting)
    }

    @Test("pose is nil at init")
    func poseNilAtInit() {
        let session = ReferenceSession(image: makeBlankImage()) { _ in throw ReferenceSessionError.noPoseDetected }
        #expect(session.pose == nil)
    }

    @Test("image is stored unchanged after init")
    func imageStoredUnchanged() {
        let image = makeBlankImage()
        let session = ReferenceSession(image: image) { _ in throw ReferenceSessionError.noPoseDetected }
        // UIImage identity: verify same instance was retained.
        #expect(session.image === image)
    }

    // MARK: - Successful extraction

    @Test("pose is non-nil after extractPose with mock returning a pose")
    func poseSetAfterSuccessfulExtraction() async {
        let expected = makeMockPose()
        let session = ReferenceSession(image: makeBlankImage()) { _ in expected }

        await session.extractPose()

        let result = try? #require(session.pose)
        #expect(result?.subjectCenterX == expected.subjectCenterX)
        #expect(result?.headroomFraction == expected.headroomFraction)
        #expect(result?.bodyKeypoints["nose_tip"] == expected.bodyKeypoints["nose_tip"])
    }

    @Test("isExtracting is false after successful extraction")
    func isExtractingFalseAfterSuccessfulExtraction() async {
        let mockPose = makeMockPose()
        let session = ReferenceSession(image: makeBlankImage()) { _ in mockPose }

        await session.extractPose()

        #expect(!session.isExtracting)
    }

    // MARK: - No body detected

    @Test("pose is nil after extractPose when mock throws noPoseDetected")
    func poseNilWhenNoPoseDetected() async {
        let session = ReferenceSession(image: makeBlankImage()) { _ in throw ReferenceSessionError.noPoseDetected }

        await session.extractPose()

        #expect(session.pose == nil)
        #expect(session.extractionError == .noPoseDetected)
    }

    @Test("isExtracting is false after extraction with no body detected")
    func isExtractingFalseAfterNoBodyDetected() async {
        let session = ReferenceSession(image: makeBlankImage()) { _ in throw ReferenceSessionError.noPoseDetected }

        await session.extractPose()

        #expect(!session.isExtracting)
    }

    // MARK: - State transitions (via Combine $isExtracting)

    /// Verifies that `$isExtracting` emits `true` during extraction and `false` after.
    ///
    /// Uses a small `Thread.sleep` inside the mock extractor to widen the window in
    /// which `isExtracting == true` is observable, then captures Published values via
    /// Combine to assert the expected sequence.
    @Test("isExtracting transitions true → false during extraction")
    func isExtractingTransitionsDuringExtraction() async {
        // Captured published values; written and read on main actor.
        var capturedValues: [Bool] = []
        var cancellable: AnyCancellable?

        let session = ReferenceSession(image: makeBlankImage()) { _ in
            // Brief blocking pause so the main actor can observe isExtracting == true.
            Thread.sleep(forTimeInterval: 0.05)
            throw ReferenceSessionError.noPoseDetected
        }

        cancellable = session.$isExtracting.sink { value in
            capturedValues.append(value)
        }

        await session.extractPose()
        cancellable?.cancel()

        // Expect at minimum: initial false, true during, false after.
        #expect(capturedValues.contains(true), "isExtracting should be true during extraction")
        #expect(capturedValues.last == false, "isExtracting should be false after extraction")
    }

    // MARK: - Timing

    @Test("extractPose completes within 500 ms using fast mock extractor")
    func extractPoseCompletesWithin500ms() async {
        let mockPose = makeMockPose()
        let session = ReferenceSession(image: makeBlankImage()) { _ in mockPose }

        let start = ContinuousClock.now
        await session.extractPose()
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(500))
    }

    // MARK: - Repeated extraction

    @Test("second extractPose overwrites pose with nil when mock returns nil")
    func secondExtractionOverwritesPoseWithNil() async {
        let mockPose = makeMockPose()
        // OSAllocatedUnfairLock is Sendable and safe to capture in a @Sendable closure.
        // It flips a flag after the first call so the same session's extractor returns
        // a pose on the first extraction and throws on the second.
        let hasReturnedOnce = OSAllocatedUnfairLock(initialState: false)

        let session = ReferenceSession(image: makeBlankImage()) { _ in
            let alreadyReturned = hasReturnedOnce.withLock { state -> Bool in
                defer { state = true }
                return state
            }
            if alreadyReturned {
                throw ReferenceSessionError.noPoseDetected
            }
            return mockPose
        }

        // First call on this session: extractor returns a valid pose.
        await session.extractPose()
        #expect(session.pose != nil)

        // Second call on the same session: extractor throws, pose is overwritten with nil.
        await session.extractPose()
        #expect(session.pose == nil)
        #expect(session.extractionError == .noPoseDetected)
        #expect(!session.isExtracting)
    }

    @Test("unexpected Vision errors surface as analysis failure")
    func unexpectedErrorIsVisible() async {
        let session = ReferenceSession(image: makeBlankImage()) { _ in
            throw NSError(domain: "Vision", code: -1)
        }
        await session.extractPose()
        #expect(session.pose == nil)
        #expect(session.extractionError == .analysisFailed)
        #expect(!session.isExtracting)
    }

    @Test("photo orientation is forwarded to Vision including mirrored images")
    func imageOrientationMapping() {
        #expect(ReferenceSession.visionOrientation(for: .up) == .up)
        #expect(ReferenceSession.visionOrientation(for: .down) == .down)
        #expect(ReferenceSession.visionOrientation(for: .left) == .left)
        #expect(ReferenceSession.visionOrientation(for: .right) == .right)
        #expect(ReferenceSession.visionOrientation(for: .upMirrored) == .upMirrored)
        #expect(ReferenceSession.visionOrientation(for: .downMirrored) == .downMirrored)
        #expect(ReferenceSession.visionOrientation(for: .leftMirrored) == .leftMirrored)
        #expect(ReferenceSession.visionOrientation(for: .rightMirrored) == .rightMirrored)
    }
}
import Foundation
import Testing
@testable import PicPal

struct SelfieReferenceTests {
    let face = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5)

    @Test func faceWithoutBodySupportsFramingButNeverPose() throws {
        let reference = try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [], geometry: ReferenceGeometry())
        var comparator = ReferenceLocalComparator()
        let result = comparator.compare(reference: reference, live: LivePoseObservation(capturedAt: 1,
            geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1, faceBox: face))
        #expect(reference.framingDomain == .face)
        #expect(result.subjectPresent)
        #expect(result.framingAligned)
        #expect(result.poseAligned == nil)
    }

    @Test func absentOrAmbiguousFacesCannotCreateSelfieReference() {
        for faces in [[], [face, face]] {
            #expect(throws: ReferenceSessionError.self) {
                try ReferenceSession.makePose(body: nil, faces: faces, personBoxes: [], geometry: ReferenceGeometry())
            }
        }
    }

    @Test func faceCannotMatchPersonRectangle() throws {
        let reference = try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [], geometry: ReferenceGeometry())
        var comparator = ReferenceLocalComparator()
        let result = comparator.compare(reference: reference, live: LivePoseObservation(capturedAt: 1,
            geometryRevision: 1, personBox: face, joints: [:], subjectCount: 1))
        #expect(!result.framingAligned)
        #expect(result.poseAligned == nil)
    }

    @Test func multipleBodiesRejectSingleFace() {
        #expect(throws: ReferenceSessionError.self) {
            try ReferenceSession.makePose(body: BodyTrackerResult(joints: [:], subjectCount: 2), faces: [face],
                personBoxes: [], geometry: ReferenceGeometry())
        }
    }
}

@Suite struct SelfieCoordinatorTests {
    @Test func faceAlignedWithoutBodyNeverRequestsFullBodyOrAutoCaptures() throws {
        let face = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5)
        let reference = try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [], geometry: ReferenceGeometry())
        var comparator = ReferenceLocalComparator()
        var coordinator = ReferenceCoachingCoordinator()
        let session = UUID()
        for time in [1.0, 1.5, 2.0, 2.5] {
            let local = comparator.compare(reference: reference, live: LivePoseObservation(capturedAt: time,
                geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 1, faceBox: face))
            let result = coordinator.update(ReferenceCoachingInput(sessionID: session, generation: 1,
                geometryRevision: 1, now: time, local: local, profile: nil, comparison: nil,
                cloudAvailability: .localOnly, captureSafe: true))
            #expect(result.caption == "Face framing aligned")
            #expect(!result.allowsAutoCapture)
            #expect(!result.referenceMatched)
        }
    }

    @Test func absentFaceAndBodyRequestsSubject() throws {
        let face = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5)
        let reference = try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [], geometry: ReferenceGeometry())
        var comparator = ReferenceLocalComparator()
        let local = comparator.compare(reference: reference, live: LivePoseObservation(capturedAt: 1,
            geometryRevision: 1, personBox: nil, joints: [:], subjectCount: 0))
        var coordinator = ReferenceCoachingCoordinator()
        let result = coordinator.update(ReferenceCoachingInput(sessionID: UUID(), generation: 1,
            geometryRevision: 1, now: 1, local: local, profile: nil, comparison: nil,
            cloudAvailability: .localOnly, captureSafe: true))
        #expect(result.caption == "Bring the person into view")
    }
}

struct SelfieLiveEvidenceTests {
    private func measured(body: BodyTrackerResult? = nil, facesAvailable: Bool = true,
                          faces: [CGRect]? = nil, people: [CGRect] = []) -> LivePoseObservation {
        .measured(capturedAt: 1, geometryRevision: 2, body: body, personBoxes: people,
            faceBoxes: faces ?? [CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5)],
            rectanglesAvailable: true, facesAvailable: facesAvailable,
            geometry: ReferenceGeometry(), backend: .mediaPipe)
    }
    @Test func failedBodyInferencePreservesLiveFace() {
        let live = measured()
        #expect(live.analysisAvailable)
        #expect(live.faceBox != nil)
        #expect(live.personBox == nil)
        #expect(live.joints.isEmpty)
        #expect(live.subjectCount == 1)
    }
    @Test func failedFaceDetectorIsUnknown() {
        #expect(!measured(facesAvailable: false).analysisAvailable)
    }
    @Test func ambiguousFacesRemainAmbiguous() {
        let face = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5)
        #expect(measured(faces: [face, face]).subjectCount == 2)
    }
    @Test func measuredMultipleSubjectsStillBlockGuidanceAndCapture() throws {
        let face = CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5)
        let reference = try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [], geometry: ReferenceGeometry())
        for live in [measured(faces: [face, face]),
                     measured(body: BodyTrackerResult(joints: [:], subjectCount: 2)),
                     measured(people: [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                                       CGRect(x: 0.5, y: 0, width: 0.5, height: 1)])] {
            var comparator = ReferenceLocalComparator()
            var coordinator = ReferenceCoachingCoordinator()
            let local = comparator.compare(reference: reference, live: live)
            let result = coordinator.update(ReferenceCoachingInput(sessionID: UUID(), generation: 1,
                geometryRevision: 2, now: 1, local: local, profile: nil, comparison: nil,
                cloudAvailability: .localOnly, captureSafe: true))
            #expect(result.caption == "Keep one person in view")
            #expect(!result.allowsAutoCapture)
            #expect(!result.referenceMatched)
            #expect(result.action == nil)
        }
    }

    @Test func disagreementDoesNotInventASecondPerson() throws {
        let live = measured(people: [CGRect(x: 0, y: 0, width: 0.1, height: 0.1)])
        #expect(live.subjectCount == 1)
        #expect(!live.analysisAvailable)
        let reference = try ReferenceSession.makePose(body: nil,
            faces: [CGRect(x: 0.25, y: 0.3, width: 0.5, height: 0.5)], personBoxes: [], geometry: ReferenceGeometry())
        var comparator = ReferenceLocalComparator()
        let local = comparator.compare(reference: reference, live: live)
        var coordinator = ReferenceCoachingCoordinator()
        let result = coordinator.update(ReferenceCoachingInput(sessionID: UUID(), generation: 1,
            geometryRevision: 2, now: 1, local: local, profile: nil, comparison: nil,
            cloudAvailability: .localOnly, captureSafe: true))
        #expect(result.caption == "Waiting for a clear view")
        #expect(!result.allowsAutoCapture)
        #expect(!result.referenceMatched)
        #expect(result.action == nil)
    }
}


struct ClippedDetectorBoxTests {
    // Measured detector output from the reported landscape selfie. No image is retained.
    let face = CGRect(x: 0.4320677221, y: 0.3998402059, width: 0.1852161139, height: 0.2469548136)
    let person = CGRect(x: 0.0628140691, y: -0.0036271811, width: 0.8802344811, height: 0.8152901313)

    @Test func liveIngestionPreservesCroppedDetectionsForClipping() {
        let detections = SubjectObservationMonitor.confidentDetections([
            VNDetectedObjectObservation(boundingBox: person)
        ])
        #expect(detections.count == 1)
        let live = LivePoseObservation.measured(capturedAt: 1, geometryRevision: 1, body: nil,
            personBoxes: detections.map(\.boundingBox), faceBoxes: [face], rectanglesAvailable: true,
            facesAvailable: true, geometry: ReferenceGeometry(), backend: .vision)
        #expect(live.analysisAvailable)
        #expect(live.subjectCount == 1)
        #expect(live.personBox?.minY == 0)
    }

    @Test func liveIngestionDoesNotHideSecondCroppedOrInvalidDetection() throws {
        for second in [CGRect(x: 0.95, y: 0.3, width: 0.2, height: 0.4),
                       CGRect(x: 1.1, y: 0.3, width: 0.2, height: 0.4)] {
            let detections = SubjectObservationMonitor.confidentDetections([
                VNDetectedObjectObservation(boundingBox: person),
                VNDetectedObjectObservation(boundingBox: second)
            ])
            #expect(detections.count == 2)
            let live = LivePoseObservation.measured(capturedAt: 1, geometryRevision: 1, body: nil,
                personBoxes: detections.map(\.boundingBox), faceBoxes: [face], rectanglesAvailable: true,
                facesAvailable: true, geometry: ReferenceGeometry(), backend: .vision)
            #expect(live.subjectCount == 2)
            var comparator = ReferenceLocalComparator()
            let reference = try ReferenceSession.makePose(body: nil, faces: [face],
                personBoxes: [], geometry: ReferenceGeometry())
            let local = comparator.compare(reference: reference, live: live)
            #expect(!local.framingAligned)
            #expect(local.poseAligned == nil)
        }
    }

    @Test func croppedSelfieRetainsReferenceAndLiveFraming() throws {
        let geometry = ReferenceGeometry(imageAspectRatio: 4.0 / 3.0)
        let reference = try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [person], geometry: geometry)
        let live = LivePoseObservation.measured(capturedAt: 1, geometryRevision: 1, body: nil,
            personBoxes: [person], faceBoxes: [face], rectanglesAvailable: true, facesAvailable: true,
            geometry: geometry, backend: .vision)
        #expect(reference.framingDomain == .face)
        #expect(live.analysisAvailable)
        #expect(live.personBox?.minY == 0)
        #expect(abs((live.personBox?.height ?? 0) - 0.8116629502) < 0.000001)
        var comparator = ReferenceLocalComparator()
        let result = comparator.compare(reference: reference, live: live)
        #expect(result.subjectPresent)
        #expect(result.framingAligned)
        #expect(result.poseAligned == nil)
    }

    @Test func edgeClippedFacesUseVisibleImageBounds() throws {
        for box in [CGRect(x: -0.01, y: 0.2, width: 0.4, height: 0.4),
                    CGRect(x: 0.7, y: 0.7, width: 0.4, height: 0.4)] {
            let reference = try ReferenceSession.makePose(body: nil, faces: [box], personBoxes: [], geometry: ReferenceGeometry())
            #expect(reference.subjectBoundingBox.minX >= 0)
            #expect(reference.subjectBoundingBox.maxX <= 1)
            #expect(reference.subjectBoundingBox.maxY <= 1)
        }
    }

    @Test func clippingDoesNotHideASecondSubject() {
        let second = CGRect(x: 0.95, y: 0.3, width: 0.2, height: 0.4)
        #expect(throws: ReferenceSessionError.self) {
            try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [person, second], geometry: ReferenceGeometry())
        }
        let live = LivePoseObservation.measured(capturedAt: 1, geometryRevision: 1, body: nil,
            personBoxes: [person, second], faceBoxes: [face], rectanglesAvailable: true, facesAvailable: true,
            geometry: ReferenceGeometry(), backend: .vision)
        #expect(live.analysisAvailable)
        #expect(live.subjectCount == 2)
        #expect(live.personBox == nil)
    }

    @Test func malformedAndInvisibleBoxesRemainUnavailable() {
        for box in [CGRect(x: 1.1, y: 0.1, width: 0.1, height: 0.1),
                    CGRect(x: 0.1, y: 0.1, width: -0.1, height: 0.1),
                    CGRect(x: 0.1, y: 0.1, width: 0, height: 0.1),
                    CGRect(x: CGFloat.nan, y: 0.1, width: 0.1, height: 0.1),
                    CGRect(x: 0.1, y: 0.1, width: CGFloat.infinity, height: 0.1)] {
            #expect(throws: ReferenceSessionError.self) {
                try ReferenceSession.makePose(body: nil, faces: [face], personBoxes: [box], geometry: ReferenceGeometry())
            }
            let live = LivePoseObservation.measured(capturedAt: 1, geometryRevision: 1, body: nil,
                personBoxes: [box], faceBoxes: [face], rectanglesAvailable: true, facesAvailable: true,
                geometry: ReferenceGeometry(), backend: .vision)
            #expect(!live.analysisAvailable)
        }
    }
}
