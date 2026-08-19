import CoreGraphics
import Testing
@testable import PicPal

// MARK: - Fixtures

private enum FilterFixture {
    /// Confidence floor used by the default filter.
    static let defaultFloor: Float = KeypointFilter.defaultConfidenceFloor
    /// A custom floor used in parameterized tests.
    static let customFloor: Float = 0.8
    /// A point value reused across tests — content is irrelevant to filtering.
    static let anyPoint = CGPoint(x: 0.5, y: 0.5)
}

// MARK: - KeypointFilterTests

/// Swift Testing suite for `KeypointFilter` and the `Keypoint` value type.
///
/// All tests are synchronous and stateless — `KeypointFilter` is a pure function.
struct KeypointFilterTests {

    // MARK: - defaultConfidenceFloor value

    @Test("defaultConfidenceFloor constant equals 0.6")
    func defaultConfidenceFloorIsPointSix() {
        #expect(KeypointFilter.defaultConfidenceFloor == 0.6)
    }

    // MARK: - Above-floor: passes through

    @Test("Keypoint above the floor is returned unchanged")
    func aboveFloorPassesThrough() {
        let kp = Keypoint(point: FilterFixture.anyPoint, confidence: 0.9)
        let result = KeypointFilter.filter(kp)
        #expect(result == kp)
    }

    // MARK: - Below-floor: discarded

    @Test("Keypoint below the floor returns nil")
    func belowFloorReturnsNil() {
        let kp = Keypoint(point: FilterFixture.anyPoint, confidence: 0.3)
        let result = KeypointFilter.filter(kp)
        #expect(result == nil)
    }

    // MARK: - Exactly at floor: passes through

    @Test("Keypoint exactly at the floor passes (>= semantics)")
    func exactlyAtFloorPasses() {
        let kp = Keypoint(
            point: FilterFixture.anyPoint,
            confidence: FilterFixture.defaultFloor
        )
        let result = KeypointFilter.filter(kp)
        #expect(result == kp)
    }

    // MARK: - Custom floor

    @Test("Custom floor parameter overrides the default")
    func customFloorIsRespected() {
        let aboveCustom = Keypoint(
            point: FilterFixture.anyPoint,
            confidence: FilterFixture.customFloor + 0.05
        )
        let belowCustom = Keypoint(
            point: FilterFixture.anyPoint,
            confidence: FilterFixture.customFloor - 0.05
        )

        #expect(KeypointFilter.filter(aboveCustom, floor: FilterFixture.customFloor) == aboveCustom)
        #expect(KeypointFilter.filter(belowCustom, floor: FilterFixture.customFloor) == nil)
    }

    // MARK: - Zero confidence

    @Test("Zero-confidence keypoint is always discarded")
    func zeroConfidenceIsDiscarded() {
        let kp = Keypoint(point: FilterFixture.anyPoint, confidence: 0.0)
        #expect(KeypointFilter.filter(kp) == nil)
    }

    // MARK: - Full confidence

    @Test("Maximum-confidence keypoint always passes")
    func maxConfidenceAlwaysPasses() {
        let kp = Keypoint(point: FilterFixture.anyPoint, confidence: 1.0)
        let result = KeypointFilter.filter(kp)
        #expect(result == kp)
    }

    // MARK: - Keypoint Equatable

    @Test("Two Keypoints with equal fields are equal")
    func keypointEquatable() {
        let a = Keypoint(point: CGPoint(x: 0.1, y: 0.2), confidence: 0.7)
        let b = Keypoint(point: CGPoint(x: 0.1, y: 0.2), confidence: 0.7)
        let c = Keypoint(point: CGPoint(x: 0.9, y: 0.2), confidence: 0.7)
        #expect(a == b)
        #expect(a != c)
    }
}
