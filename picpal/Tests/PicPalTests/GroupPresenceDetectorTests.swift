import CoreGraphics
import Testing
@testable import PicPal

// MARK: - Fixture values

private enum Fixture {
    // Confidence values
    static let highConfidence: Float = 0.80
    static let atFloor: Float = GroupPresenceDetector.minimumBodyConfidence  // 0.4 -- qualifies
    static let belowFloor: Float = 0.30                                      // excluded

    // Bounding boxes in Vision coords (origin bottom-left, y-up)
    static let leftBox  = CGRect(x: 0.10, y: 0.20, width: 0.30, height: 0.50)  // maxX=0.40, maxY=0.70
    static let rightBox = CGRect(x: 0.50, y: 0.10, width: 0.20, height: 0.60)  // maxX=0.70, maxY=0.70
    // Union of leftBox and rightBox:
    // minX=0.10, minY=0.10, maxX=0.70, maxY=0.70 -> width=0.60, height=0.60
    static let expectedUnion = CGRect(x: 0.10, y: 0.10, width: 0.60, height: 0.60)
    static let expectedSpread: Float  = 0.60   // union.width
    static let expectedLeftMargin: Float  = 0.10   // union.minX
    static let expectedRightMargin: Float = 0.30   // 1.0 - union.maxX (1.0 - 0.70)
    static let expectedHeadroom: Float    = 0.30   // 1.0 - union.maxY (1.0 - 0.70)

    static let floatTolerance: Float = 0.0001
}

// MARK: - GroupPresenceDetectorTests

/// Swift Testing suite for `GroupPresenceDetector` geometry and confidence-filtering logic.
///
/// `VNHumanBodyPoseObservation` cannot be constructed in unit tests (Vision private
/// initialiser). Tests call `detect(pairs:)` with synthetic confidence/bounding-box
/// tuples to exercise the same logic path as the production `detect(from observations:)`.
struct GroupPresenceDetectorTests {

    private let detector = GroupPresenceDetector()

    // MARK: - 1. Empty observations -> nil

    @Test("Zero observations returns nil")
    func emptyObservationsReturnsNil() {
        let result = detector.detect(pairs: [])
        #expect(result == nil)
    }

    // MARK: - 2. Single qualified observation -> nil (need >= 2)

    @Test("One qualified observation returns nil")
    func singleQualifiedObservationReturnsNil() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(result == nil)
    }

    // MARK: - 3. Two qualified observations -> non-nil with personCount=2

    @Test("Two qualified observations returns non-nil GroupPresence with personCount 2")
    func twoQualifiedObservationsReturnsGroupPresence() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.highConfidence, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(result != nil)
        #expect(result?.personCount == 2)
    }

    // MARK: - 4. Three qualified observations -> personCount=3

    @Test("Three qualified observations returns personCount 3")
    func threeQualifiedObservationsReturnsCount3() {
        let thirdBox = CGRect(x: 0.30, y: 0.05, width: 0.10, height: 0.20)
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.highConfidence, Fixture.rightBox),
            (Fixture.highConfidence, thirdBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(result?.personCount == 3)
    }

    // MARK: - 5. Confidence filtering: one below floor -> only one qualifies -> nil

    @Test("One observation above floor and one below floor returns nil")
    func oneBelowFloorYieldsNil() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.belowFloor,     Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(result == nil)
    }

    // MARK: - 6. Confidence exactly at floor qualifies

    @Test("Observation with confidence exactly at minimumBodyConfidence qualifies")
    func atFloorConfidenceQualifies() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.atFloor, Fixture.leftBox),
            (Fixture.atFloor, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(result != nil)
        #expect(result?.personCount == 2)
    }

    // MARK: - 7. All below floor -> nil

    @Test("All observations below confidence floor returns nil")
    func allBelowFloorReturnsNil() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.belowFloor, Fixture.leftBox),
            (Fixture.belowFloor, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(result == nil)
    }

    // MARK: - 8. Correct union bounding box

    @Test("Union bounding box is the geometric union of all qualified boxes")
    func unionBoundingBoxIsCorrect() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.highConfidence, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        guard let presence = result else {
            Issue.record("Expected non-nil GroupPresence")
            return
        }
        #expect(abs(Float(presence.unionBoundingBox.minX) - Float(Fixture.expectedUnion.minX)) < Fixture.floatTolerance)
        #expect(abs(Float(presence.unionBoundingBox.minY) - Float(Fixture.expectedUnion.minY)) < Fixture.floatTolerance)
        #expect(abs(Float(presence.unionBoundingBox.maxX) - Float(Fixture.expectedUnion.maxX)) < Fixture.floatTolerance)
        #expect(abs(Float(presence.unionBoundingBox.maxY) - Float(Fixture.expectedUnion.maxY)) < Fixture.floatTolerance)
    }

    // MARK: - 9. Correct spreadFraction

    @Test("spreadFraction equals union box width")
    func spreadFractionEqualsUnionWidth() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.highConfidence, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(abs((result?.spreadFraction ?? 0) - Fixture.expectedSpread) < Fixture.floatTolerance)
    }

    // MARK: - 10. Correct leftMargin

    @Test("leftMargin equals union box minX")
    func leftMarginEqualsUnionMinX() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.highConfidence, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(abs((result?.leftMargin ?? 0) - Fixture.expectedLeftMargin) < Fixture.floatTolerance)
    }

    // MARK: - 11. Correct rightMargin

    @Test("rightMargin equals 1.0 minus union box maxX")
    func rightMarginEqualsOneMinusMaxX() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.highConfidence, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(abs((result?.rightMargin ?? 0) - Fixture.expectedRightMargin) < Fixture.floatTolerance)
    }

    // MARK: - 12. Correct headroomFraction (Vision y-up: top = 1.0)

    @Test("headroomFraction equals 1.0 minus union box maxY")
    func headroomFractionEqualsOneMinusMaxY() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.highConfidence, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(abs((result?.headroomFraction ?? 0) - Fixture.expectedHeadroom) < Fixture.floatTolerance)
    }

    // MARK: - 13. Mixed confidence: two qualified out of three -> personCount=2

    @Test("Mixed confidence: two qualified out of three observations yields personCount 2")
    func mixedConfidenceYieldsCorrectCount() {
        let pairs: [(confidence: Float, boundingBox: CGRect)] = [
            (Fixture.highConfidence, Fixture.leftBox),
            (Fixture.belowFloor,     CGRect(x: 0.9, y: 0.9, width: 0.05, height: 0.05)),
            (Fixture.highConfidence, Fixture.rightBox),
        ]
        let result = detector.detect(pairs: pairs)
        #expect(result?.personCount == 2)
        // The below-floor observation should not inflate the union box.
        #expect(abs((result?.rightMargin ?? 0) - Fixture.expectedRightMargin) < Fixture.floatTolerance)
    }
}
