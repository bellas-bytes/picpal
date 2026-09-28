import Testing
import UIKit
@testable import PicPal

// MARK: - ReferenceOverlayViewTests

/// Behavioural tests for `ReferenceOverlayView`.
///
/// Pure SwiftUI rendering is not exercised here (no ViewInspector dependency).
/// Instead, these tests verify the view's logic surface:
///   - `currentOpacity` for every state combination
///   - `onDismiss` callback is captured and callable
///
@Suite("ReferenceOverlayView") @MainActor
struct ReferenceOverlayViewTests {

    // MARK: - Helpers

    /// Returns a minimal 1 × 1 blank `UIImage` — sufficient to satisfy the `image`
    /// parameter without triggering Vision or PhotosUI.
    private func makeBlankImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        return renderer.image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    // MARK: - currentOpacity tests

    @Test("currentOpacity returns 0.30 when idle (not matched, not extracting)")
    func currentOpacityDefault() {
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: false,
            isExtracting: false,
            onDismiss: {}
        )
        #expect(view.currentOpacity == 0.30)
    }

    @Test("currentOpacity returns 0.30 when matched")
    func currentOpacityMatched() {
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: true,
            isExtracting: false,
            onDismiss: {}
        )
        #expect(view.currentOpacity == 0.30)
    }

    @Test("currentOpacity returns 0.30 when extracting")
    func currentOpacityExtracting() {
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: false,
            isExtracting: true,
            onDismiss: {}
        )
        #expect(view.currentOpacity == 0.30)
    }

    @Test("currentOpacity returns 0.30 when extracting preserves selected opacity")
    func currentOpacityExtractingTakesPriority() {
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: true,
            isExtracting: true,
            onDismiss: {}
        )
        // Matching and extraction preserve the selected opacity.
        #expect(view.currentOpacity == 0.30)
    }

    @Test func selectedOpacityPersistsAcrossAnalysisStates() {
        for matched in [false, true] {
            for extracting in [false, true] {
                let view = ReferenceOverlayView(image: makeBlankImage(), isMatched: matched,
                    isExtracting: extracting, opacity: 0.72, onDismiss: {})
                #expect(view.currentOpacity == 0.72)
            }
        }
    }

    @Test func zeroOpacityHidesGhostAndMatchTintButKeepsDismissal() {
        var dismissed = false
        let view = ReferenceOverlayView(image: makeBlankImage(), isMatched: true, isExtracting: false,
            opacity: 0, onDismiss: { dismissed = true })
        #expect(view.currentOpacity == 0)
        #expect(view.matchTintOpacity == 0)
        view.onDismiss()
        #expect(dismissed)
    }

    // MARK: - onDismiss tests

    @Test("onDismiss callback fires when called")
    func onDismissCallbackFires() {
        var dismissed = false
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: false,
            isExtracting: false,
            onDismiss: { dismissed = true }
        )
        view.onDismiss()
        #expect(dismissed)
    }

    @Test("onDismiss callback can be called multiple times")
    func onDismissCallbackIsRepeatable() {
        var callCount = 0
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: false,
            isExtracting: false,
            onDismiss: { callCount += 1 }
        )
        view.onDismiss()
        view.onDismiss()
        #expect(callCount == 2)
    }

    // MARK: - extractionFailed tests

    @Test("extractionFailed defaults to false")
    func extractionFailedDefaultsFalse() {
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: false,
            isExtracting: false,
            onDismiss: {}
        )
        #expect(view.extractionFailed == false)
    }

    @Test("extractionFailed is stored as provided")
    func extractionFailedIsStored() {
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: false,
            isExtracting: false,
            extractionFailed: true,
            onDismiss: {}
        )
        #expect(view.extractionFailed == true)
    }

    // MARK: - Stored property tests

    @Test("image property is stored unchanged")
    func imageIsStoredUnchanged() {
        let original = makeBlankImage()
        let view = ReferenceOverlayView(
            image: original,
            isMatched: false,
            isExtracting: false,
            onDismiss: {}
        )
        #expect(view.image === original)
    }

    @Test("isMatched and isExtracting are stored as provided")
    func storedPropertiesMatchInit() {
        let view = ReferenceOverlayView(
            image: makeBlankImage(),
            isMatched: true,
            isExtracting: true,
            onDismiss: {}
        )
        #expect(view.isMatched)
        #expect(view.isExtracting)
    }
}
