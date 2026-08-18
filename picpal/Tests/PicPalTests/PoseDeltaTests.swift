import Testing
import CoreGraphics
@testable import PicPal

struct PoseDeltaTests {

    // MARK: - isWithinThreshold: all components within threshold

    @Test("All components within their thresholds returns true")
    func allComponentsWithinThresholdReturnsTrue() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == true)
    }

    @Test("All components at zero returns true")
    func allComponentsAtZeroReturnsTrue() {
        let delta = PoseDelta(
            horizontalOffset: 0.0,
            verticalOffset: 0.0,
            headroomDelta: 0.0,
            scaleDelta: 0.0,
            faceYawDelta: 0.0
        )
        #expect(delta.isWithinThreshold == true)
    }

    @Test("All components near upper threshold boundary returns true")
    func allComponentsNearUpperBoundaryReturnsTrue() {
        let delta = PoseDelta(
            horizontalOffset: 0.079,
            verticalOffset: 0.079,
            headroomDelta: 0.079,
            scaleDelta: 0.149,
            faceYawDelta: 0.149
        )
        #expect(delta.isWithinThreshold == true)
    }

    // MARK: - isWithinThreshold: horizontal offset exceeds threshold

    @Test("Horizontal offset exceeds threshold returns false")
    func horizontalOffsetExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.09,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    @Test("Negative horizontal offset exceeds threshold returns false")
    func negativeHorizontalOffsetExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: -0.09,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    // MARK: - isWithinThreshold: vertical offset exceeds threshold

    @Test("Vertical offset exceeds threshold returns false")
    func verticalOffsetExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.09,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    @Test("Negative vertical offset exceeds threshold returns false")
    func negativeVerticalOffsetExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: -0.09,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    // MARK: - isWithinThreshold: headroom delta exceeds threshold

    @Test("Headroom delta exceeds threshold returns false")
    func headroomDeltaExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.09,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    @Test("Negative headroom delta exceeds threshold returns false")
    func negativeHeadroomDeltaExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: -0.09,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    // MARK: - isWithinThreshold: scale delta exceeds scale threshold

    @Test("Scale delta exceeds scale threshold returns false")
    func scaleDeltaExceedsScaleThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.16,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    @Test("Negative scale delta exceeds scale threshold returns false")
    func negativeScaleDeltaExceedsScaleThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: -0.16,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    // MARK: - isWithinThreshold: face yaw delta exceeds threshold

    @Test("Face yaw delta exceeds threshold returns false")
    func faceYawDeltaExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.16
        )
        #expect(delta.isWithinThreshold == false)
    }

    @Test("Negative face yaw delta exceeds threshold returns false")
    func negativeYawDeltaExceedsThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: -0.16
        )
        #expect(delta.isWithinThreshold == false)
    }

    // MARK: - isWithinThreshold: nil face yaw is treated as matched

    @Test("Nil face yaw delta is treated as matched")
    func nilFaceYawDeltaTreatedAsMatched() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: nil
        )
        #expect(delta.isWithinThreshold == true)
    }

    @Test("Nil face yaw with other components within threshold returns true")
    func nilFaceYawWithOtherComponentsWithinThresholdReturnsTrue() {
        let delta = PoseDelta(
            horizontalOffset: 0.07,
            verticalOffset: 0.07,
            headroomDelta: 0.07,
            scaleDelta: 0.14,
            faceYawDelta: nil
        )
        #expect(delta.isWithinThreshold == true)
    }

    // MARK: - Named constants are used (not magic numbers)

    @Test("Default match threshold is 0.08")
    func defaultMatchThresholdIs008() {
        #expect(PoseDelta.defaultMatchThreshold == 0.08)
    }

    @Test("Default scale match threshold is 0.15")
    func defaultScaleMatchThresholdIs015() {
        #expect(PoseDelta.defaultScaleMatchThreshold == 0.15)
    }

    // MARK: - Edge cases: exactly at boundary

    @Test("Horizontal offset exactly at threshold boundary excludes it")
    func horizontalOffsetAtBoundaryExcludesIt() {
        let delta = PoseDelta(
            horizontalOffset: 0.08,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    @Test("Scale delta exactly at scale threshold boundary excludes it")
    func scaleDeltaAtBoundaryExcludesIt() {
        let delta = PoseDelta(
            horizontalOffset: 0.01,
            verticalOffset: 0.01,
            headroomDelta: 0.01,
            scaleDelta: 0.15,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }

    // MARK: - Multiple violations

    @Test("Multiple components exceeding threshold returns false")
    func multipleComponentsExceedingThresholdReturnsFalse() {
        let delta = PoseDelta(
            horizontalOffset: 0.09,
            verticalOffset: 0.09,
            headroomDelta: 0.01,
            scaleDelta: 0.10,
            faceYawDelta: 0.10
        )
        #expect(delta.isWithinThreshold == false)
    }
}
