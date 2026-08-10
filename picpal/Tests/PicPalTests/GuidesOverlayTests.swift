import CoreGraphics
import Testing
@testable import PicPal

/// Tests for the Vision → SwiftUI coordinate conversion helper.
///
/// Vision uses a normalized coordinate space with origin at bottom-left (y increases up).
/// SwiftUI uses origin at top-left (y increases down). `visionRectToSwiftUI` bridges the gap.
@Suite("GuidesOverlay coordinate conversion")
struct GuidesOverlayTests {

    private let screenSize = CGSize(width: 390, height: 844)

    @Test("Vision origin-bottom-left converts to SwiftUI origin-top-left")
    func visionRectConversion() {
        // A small rect in the bottom-left of Vision space (y ~ 0) should land near
        // the top-left in SwiftUI space (y ~ 0 after flip).
        let visionRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let result = visionRectToSwiftUI(visionRect, in: screenSize)

        // minX should scale by width
        #expect(abs(result.minX - 0.1 * screenSize.width) < 0.001)

        // After flipping: uiKitY = 1 - visionRect.maxY = 1 - 0.3 = 0.7 → scaled
        let expectedMinY = (1 - visionRect.maxY) * screenSize.height
        #expect(abs(result.minY - expectedMinY) < 0.001)

        // Width and height remain unchanged (just scaled)
        #expect(abs(result.width - visionRect.width * screenSize.width) < 0.001)
        #expect(abs(result.height - visionRect.height * screenSize.height) < 0.001)
    }

    @Test("Vision rect fills full frame correctly")
    func fullFrameVisionRect() {
        // A unit rect in Vision space should map to the full screen size in SwiftUI.
        let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)
        let result = visionRectToSwiftUI(fullFrame, in: screenSize)

        #expect(abs(result.minX) < 0.001)
        #expect(abs(result.minY) < 0.001)
        #expect(abs(result.width - screenSize.width) < 0.001)
        #expect(abs(result.height - screenSize.height) < 0.001)
    }

    @Test("Vision rect at top of frame maps to top in SwiftUI")
    func topVisionRectMapsToTopSwiftUI() {
        // In Vision coords, y close to 1 means near the top of the image.
        // After flipping, this should be near y = 0 in SwiftUI.
        let topRect = CGRect(x: 0.3, y: 0.8, width: 0.4, height: 0.15)
        let result = visionRectToSwiftUI(topRect, in: screenSize)

        // uiKitY = 1 - maxY = 1 - 0.95 = 0.05 → near top of screen
        let expectedMinY = (1 - topRect.maxY) * screenSize.height
        #expect(abs(result.minY - expectedMinY) < 0.001)
        #expect(result.minY < screenSize.height * 0.1,
                "Top-of-vision rect should be in the top 10% of screen")
    }

    @Test("Vision rect at bottom of frame maps to bottom in SwiftUI")
    func bottomVisionRectMapsToBottomSwiftUI() {
        // In Vision coords, y near 0 = bottom of image → near bottom of SwiftUI view.
        let bottomRect = CGRect(x: 0.2, y: 0.05, width: 0.3, height: 0.1)
        let result = visionRectToSwiftUI(bottomRect, in: screenSize)

        // uiKitY = 1 - maxY = 1 - 0.15 = 0.85 → near bottom
        let expectedMinY = (1 - bottomRect.maxY) * screenSize.height
        #expect(abs(result.minY - expectedMinY) < 0.001)
        #expect(result.minY > screenSize.height * 0.5,
                "Bottom-of-vision rect should be in the lower half of screen")
    }
}
