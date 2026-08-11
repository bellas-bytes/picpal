import Testing
import CoreGraphics
@testable import PicPal

// MARK: - Coordinate reference values

private enum CoordinateFixture {
    // Vision bottom-left corner
    static let visionBottomLeft    = CGPoint(x: 0.0, y: 0.0)
    // Vision top-left corner (in Vision space, y=1 is the top)
    static let visionTopLeft       = CGPoint(x: 0.0, y: 1.0)
    // Vision centre — invariant across the Y-flip
    static let visionCenter        = CGPoint(x: 0.5, y: 0.5)

    // Expected UIKit equivalents
    static let uiKitBottomEdge     = CGPoint(x: 0.0, y: 1.0) // Vision y=0 → UIKit y=1
    static let uiKitTopEdge        = CGPoint(x: 0.0, y: 0.0) // Vision y=1 → UIKit y=0
    static let uiKitCenter         = CGPoint(x: 0.5, y: 0.5)

    // MediaPipe pass-through
    static let mediapipePoint      = CGPoint(x: 0.3, y: 0.7)

    // Rect test fixtures
    static let visionRect          = CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.2)
    //  visionRect.maxY = 0.5  →  UIKit minY = 1 − 0.5 = 0.5
    static let uiKitRectMinY: CGFloat = 0.5
    static let mediapipeRect       = CGRect(x: 0.2, y: 0.4, width: 0.3, height: 0.1)
}

// MARK: - Point conversion tests

/// Tests for `LandmarkCoordinates` — the unified Vision/MediaPipe → UIKit
/// coordinate-conversion helper introduced in M2-0.
struct LandmarkCoordinateTests {

    // MARK: - Vision point: mandatory brief cases

    @Test("Vision bottom-left (0,0) maps to UIKit (0,1)")
    func visionBottomLeftMapsToUIKitBottomEdge() {
        let result = LandmarkCoordinates.visionPointToUIKit(CoordinateFixture.visionBottomLeft)
        #expect(result == CoordinateFixture.uiKitBottomEdge)
    }

    @Test("Vision top-left in Vision space (0,1) maps to UIKit origin (0,0)")
    func visionTopLeftMapsToUIKitOrigin() {
        let result = LandmarkCoordinates.visionPointToUIKit(CoordinateFixture.visionTopLeft)
        #expect(result == CoordinateFixture.uiKitTopEdge)
    }

    @Test("Vision centre (0.5,0.5) is invariant under Y-flip")
    func visionCentreIsInvariant() {
        let result = LandmarkCoordinates.visionPointToUIKit(CoordinateFixture.visionCenter)
        #expect(result == CoordinateFixture.uiKitCenter)
    }

    @Test("MediaPipe point (0.3,0.7) passes through unchanged to UIKit")
    func mediapipePointIsPassThrough() {
        let result = LandmarkCoordinates.mediapipePointToUIKit(CoordinateFixture.mediapipePoint)
        #expect(result == CoordinateFixture.mediapipePoint)
    }

    // MARK: - Additional Vision point cases

    @Test("Vision top-right corner (1,1) maps to UIKit top-right (1,0)")
    func visionTopRightMapsToUIKitTopRight() {
        let input = CGPoint(x: 1.0, y: 1.0)
        let result = LandmarkCoordinates.visionPointToUIKit(input)
        #expect(result == CGPoint(x: 1.0, y: 0.0))
    }

    @Test("Vision bottom-right corner (1,0) maps to UIKit bottom-right (1,1)")
    func visionBottomRightMapsToUIKitBottomRight() {
        let input = CGPoint(x: 1.0, y: 0.0)
        let result = LandmarkCoordinates.visionPointToUIKit(input)
        #expect(result == CGPoint(x: 1.0, y: 1.0))
    }

    @Test("visionPointToUIKit applied twice is identity (double-flip)")
    func visionPointDoubleFlipIsIdentity() {
        let original = CGPoint(x: 0.25, y: 0.75)
        let flippedOnce  = LandmarkCoordinates.visionPointToUIKit(original)
        let flippedTwice = LandmarkCoordinates.visionPointToUIKit(flippedOnce)
        #expect(flippedTwice == original)
    }

    // MARK: - Rect conversion tests

    @Test("Vision rect Y-axis flips correctly: minY = 1 − maxY of input")
    func visionRectFlipsYAxis() {
        let result = LandmarkCoordinates.visionRectToUIKit(CoordinateFixture.visionRect)
        #expect(result.minX == CoordinateFixture.visionRect.minX)
        #expect(result.minY == CoordinateFixture.uiKitRectMinY)
        #expect(result.width == CoordinateFixture.visionRect.width)
        #expect(result.height == CoordinateFixture.visionRect.height)
    }

    @Test("MediaPipe rect passes through unchanged to UIKit")
    func mediapipeRectIsPassThrough() {
        let result = LandmarkCoordinates.mediapipeRectToUIKit(CoordinateFixture.mediapipeRect)
        #expect(result == CoordinateFixture.mediapipeRect)
    }

    // MARK: - X-axis invariance

    @Test("visionPointToUIKit does not modify the X coordinate")
    func xCoordinateIsUnchanged() {
        let testX: CGFloat = 0.42
        let input  = CGPoint(x: testX, y: 0.0)
        let result = LandmarkCoordinates.visionPointToUIKit(input)
        #expect(result.x == testX)
    }
}
