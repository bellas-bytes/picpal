import Testing
import CoreGraphics
@testable import PicPal

// MARK: - ReferenceIntegrationTests

/// Integration tests for the reference-photo coaching pipeline.
///
/// Exercises legacy coordinate conversion. Reference matching and production camera
/// integration are covered by ReferenceCoachingCoordinatorTests and CameraReferenceCoachingTests.
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

}
