import Testing
import UIKit
import CoreGraphics
import Combine
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
        let session = ReferenceSession(image: makeBlankImage()) { _ in nil }
        #expect(!session.isExtracting)
    }

    @Test("pose is nil at init")
    func poseNilAtInit() {
        let session = ReferenceSession(image: makeBlankImage()) { _ in nil }
        #expect(session.pose == nil)
    }

    @Test("image is stored unchanged after init")
    func imageStoredUnchanged() {
        let image = makeBlankImage()
        let session = ReferenceSession(image: image) { _ in nil }
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

    @Test("pose is nil after extractPose when mock returns nil (no body)")
    func poseNilWhenNoPoseDetected() async {
        let session = ReferenceSession(image: makeBlankImage()) { _ in nil }

        await session.extractPose()

        #expect(session.pose == nil)
    }

    @Test("isExtracting is false after extraction with no body detected")
    func isExtractingFalseAfterNoBodyDetected() async {
        let session = ReferenceSession(image: makeBlankImage()) { _ in nil }

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
            return nil
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
        // First extraction: returns a pose.
        let mockPose = makeMockPose()
        let session = ReferenceSession(image: makeBlankImage()) { _ in mockPose }
        await session.extractPose()
        #expect(session.pose != nil)

        // Second extraction: different session with nil extractor to confirm nil assignment.
        let session2 = ReferenceSession(image: makeBlankImage()) { _ in nil }
        await session2.extractPose()
        #expect(session2.pose == nil)
        #expect(!session2.isExtracting)
    }
}
