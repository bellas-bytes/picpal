import Testing
import CoreGraphics
@testable import PicPal

// MARK: - FramingProcessorTests

/// Tests for `FramingProcessor.process(subjectBox:)`.
///
/// All tests exercise pure compositional logic only — no Vision, no AVFoundation,
/// no pixel buffers. Vision coords (origin bottom-left) are used when constructing
/// bounding boxes; the processor converts them to UIKit coords internally.
struct FramingProcessorTests {

    // MARK: - Named constants (mirrors FramingProcessor internals)

    private static let oneThird:  Double = 1.0 / 3.0
    private static let twoThirds: Double = 2.0 / 3.0

    // MARK: - Helpers

    /// Builds a Vision-normalized `CGRect` whose centre lands at the given
    /// Vision coordinates (origin bottom-left).
    ///
    /// - Parameters:
    ///   - visionCX: Horizontal centre in Vision coords (same as UIKit horizontal).
    ///   - visionCY: Vertical centre in Vision coords (0 = bottom, 1 = top).
    ///   - side: Side length of the square bounding box (default 0.1).
    private func box(visionCX: Double, visionCY: Double, side: Double = 0.1) -> CGRect {
        CGRect(
            x: visionCX - side / 2,
            y: visionCY - side / 2,
            width: side,
            height: side
        )
    }

    // MARK: - Test 1: nil subject → noSubject

    @Test("nil subject box produces noSubject hint")
    func nilSubjectProducesNoSubject() {
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: nil)
        #expect(signal.hint == .noSubject)
        #expect(signal.subjectBox == nil)
    }

    // MARK: - Test 2: centred subject → tooCentered

    @Test("Subject centred at frame origin (0.5, 0.5) produces tooCentered hint")
    func centredSubjectProducesTooCentered() {
        // Vision centre (0.5, 0.5) → UIKit centre (0.5, 0.5) — dead centre.
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: box(visionCX: 0.5, visionCY: 0.5))
        #expect(signal.hint == .tooCentered)
    }

    // MARK: - Test 3: subject at left edge → nudgeRight

    @Test("Subject at left edge produces nudgeRight hint")
    func subjectAtLeftEdgeProducesNudgeRight() {
        // Vision centre (0.05, 0.5) → UIKit centre (0.05, 0.5).
        // Nearest thirds point: (1/3, 1/3) or (1/3, 2/3) — both equidistant;
        // horizontal offset = 0.05 − 1/3 ≈ −0.283 (negative → nudgeRight).
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: box(visionCX: 0.05, visionCY: 0.5))
        #expect(signal.hint == .nudgeRight)
    }

    // MARK: - Test 4: subject at right edge → nudgeLeft

    @Test("Subject at right edge produces nudgeLeft hint")
    func subjectAtRightEdgeProducesNudgeLeft() {
        // Vision centre (0.95, 0.5) → UIKit centre (0.95, 0.5).
        // Nearest thirds point: (2/3, 1/3) or (2/3, 2/3);
        // horizontal offset = 0.95 − 2/3 ≈ +0.283 (positive → nudgeLeft).
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: box(visionCX: 0.95, visionCY: 0.5))
        #expect(signal.hint == .nudgeLeft)
    }

    // MARK: - Test 5: subject exactly on thirds intersection → goodFrame

    @Test("Subject on thirds intersection produces goodFrame hint")
    func subjectOnThirdsIntersectionProducesGoodFrame() {
        // Want UIKit centre (1/3, 1/3).
        // UIKit centerY = 1 − visionCY = 1/3 → visionCY = 2/3.
        let processor = FramingProcessor()
        let signal = processor.process(
            subjectBox: box(visionCX: Self.oneThird, visionCY: Self.twoThirds)
        )
        #expect(signal.hint == .goodFrame)
    }

    // MARK: - Test 6: subject near top of frame → nudgeDown

    @Test("Subject near top of frame produces nudgeDown hint")
    func subjectNearTopProducesNudgeDown() {
        // Vision centre (1/3, 0.95) → UIKit centre (1/3, 0.05).
        // Nearest thirds point: (1/3, 1/3).
        // horizontalOffset ≈ 0 (within dead zone).
        // verticalOffset = 0.05 − 1/3 ≈ −0.283 (negative → nudgeDown).
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: box(visionCX: Self.oneThird, visionCY: 0.95))
        #expect(signal.hint == .nudgeDown)
    }

    // MARK: - Test 7: small offset within default dead zone → goodFrame vs nudgeLeft with tighter zone

    @Test("Custom dead-zone fraction changes classification from goodFrame to nudgeLeft")
    func customDeadZoneAffectsClassification() {
        // Vision centre (1/3 + 0.02, 2/3) → UIKit centre (1/3 + 0.02, 1/3).
        // Nearest thirds point: (1/3, 1/3); horizontalOffset = +0.02.

        let testBox = box(visionCX: Self.oneThird + 0.02, visionCY: Self.twoThirds)

        // With default dead zone (0.05): 0.02 < 0.05 → horizontal OK → goodFrame.
        let defaultProcessor = FramingProcessor()
        #expect(defaultProcessor.process(subjectBox: testBox).hint == .goodFrame)

        // With tighter dead zone (0.01): 0.02 > 0.01 → horizontal NOT OK → nudgeLeft.
        let tightProcessor = FramingProcessor(deadZoneFraction: 0.01)
        #expect(tightProcessor.process(subjectBox: testBox).hint == .nudgeLeft)
    }

    // MARK: - Test 8: defaultDeadZoneFraction is accessible as a named constant

    @Test("defaultDeadZoneFraction is accessible and equals 0.05")
    func defaultDeadZoneFractionConstantIsAccessible() {
        #expect(FramingProcessor.defaultDeadZoneFraction == 0.05)
    }

    // MARK: - Test 9: defaultCenterDeadZoneFraction constant

    @Test("defaultCenterDeadZoneFraction is accessible and equals 0.10")
    func defaultCenterDeadZoneFractionConstantIsAccessible() {
        #expect(FramingProcessor.defaultCenterDeadZoneFraction == 0.10)
    }

    // MARK: - Test 10: subjectBox is stored on non-nil result

    @Test("Non-nil subject box is stored in the returned FramingSignal")
    func subjectBoxIsStoredOnNonNilResult() {
        let testBox = box(visionCX: 0.5, visionCY: 0.5)
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: testBox)
        #expect(signal.subjectBox == testBox)
    }

    // MARK: - Test 11: near top-right → nudgeLeft dominates nudgeDown

    @Test("Subject near top-right corner picks dominant horizontal nudge")
    func topRightSubjectPicksDominantHorizontalNudge() {
        // Vision centre (0.95, 0.8) → UIKit centre (0.95, 0.2).
        // Nearest thirds: (2/3, 1/3).
        // horizontalOffset = 0.95 − 2/3 ≈ +0.283.
        // verticalOffset   = 0.20 − 1/3 ≈ −0.133.
        // |horizontal| > |vertical| → nudgeLeft.
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: box(visionCX: 0.95, visionCY: 0.8))
        #expect(signal.hint == .nudgeLeft)
    }

    // MARK: - Test 12: subject above nearest thirds line → nudgeUp

    @Test("Subject above nearest thirds line emits nudgeUp")
    func subjectAboveThirdsLineEmitsNudgeUp() {
        // Vision centre (1/3, 0.6) → UIKit centre (1/3, 0.4).
        // Nearest thirds point: (1/3, 1/3).
        // horizontalOffset = 1/3 − 1/3 = 0.0 → horizontal OK.
        // verticalOffset   = 0.4 − 1/3 ≈ +0.067 (> 0) → subject above thirds → nudgeUp.
        let processor = FramingProcessor()
        let signal = processor.process(subjectBox: box(visionCX: 1.0 / 3.0, visionCY: 0.6))
        #expect(signal.hint == .nudgeUp)
    }
}
