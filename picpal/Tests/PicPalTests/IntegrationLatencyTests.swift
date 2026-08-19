import CoreVideo
import Testing
@testable import PicPal

// MARK: - Helpers

/// Reference-type wrapper to safely capture a `SignalFrame` in a `@Sendable` closure.
///
/// Swift 6 forbids capturing a `var` in a `@Sendable` closure. Wrapping the
/// mutable value in an `@unchecked Sendable` class avoids that restriction
/// while keeping `update(tilt:)` synchronous in tests.
private final class FrameCapture: @unchecked Sendable {
    var frame: SignalFrame?
}

// MARK: - IntegrationLatencyTests

/// End-to-end validation of the signal → cue pipeline in a synthetic harness.
///
/// No camera, Vision, or AVFoundation — all signals are constructed directly.
/// The pipeline under test:
///   TiltSignal (bad) → SignalFrameAccumulator → CueEngine → CueEvaluator
struct IntegrationLatencyTests {

    // MARK: - Test 1: Latency

    @Test("Cue engine produces tilt cue within 1ms on simulated bad frame")
    func cueEngineProducesCueWithin1ms() {
        let engine = CueEngine()
        let badTilt = TiltSignal(angleDegrees: 5.0, isLevel: false)
        let frame = SignalFrame(timestamp: 1.0, tilt: badTilt)
        let start = Date()
        let cue = engine.process(frame: frame)
        let elapsed = Date().timeIntervalSince(start) * 1000 // ms
        #expect(cue != nil)
        #expect(elapsed < 1.0)  // well under 1ms for pure logic
    }

    // MARK: - Test 2: Good frame → silence

    @Test("CueEvaluator returns nil for a clean frame")
    func evaluatorReturnsNilForCleanFrame() {
        let evaluator = CueEvaluator()
        let cleanTilt    = TiltSignal(angleDegrees: 0.0, isLevel: true)
        let cleanBlur    = BlurSignal(sharpnessScore: 100.0, isBlurry: false)
        let cleanExp     = ExposureSignal(shadowClipFraction: 0.01,
                                         highlightClipFraction: 0.01, level: .ok)
        let goodFraming  = FramingSignal(subjectBox: nil, hint: .goodFrame)
        let frame = SignalFrame(timestamp: 1.0, tilt: cleanTilt, blur: cleanBlur,
                                exposure: cleanExp, framing: goodFraming)
        #expect(evaluator.evaluate(frame: frame) == nil)
    }

    // MARK: - Test 3: Priority ordering

    @Test("Tilt signal has higher priority than framing nudge")
    func tiltOutranksFramingNudge() {
        let evaluator  = CueEvaluator()
        let badTilt    = TiltSignal(angleDegrees: 5.0, isLevel: false)
        let badFraming = FramingSignal(subjectBox: nil, hint: .nudgeLeft)
        let frame = SignalFrame(timestamp: 1.0, tilt: badTilt, framing: badFraming)
        let cue = evaluator.evaluate(frame: frame)
        #expect(cue?.priority == .stability)
    }

    // MARK: - Test 4: Accumulator merging

    @Test("SignalFrameAccumulator merges tilt into existing frame")
    func accumulatorMergesTilt() {
        let capture = FrameCapture()
        let accum = SignalFrameAccumulator { frame in capture.frame = frame }
        let tilt = TiltSignal(angleDegrees: 3.0, isLevel: false)
        accum.update(tilt: tilt)
        #expect(capture.frame?.tilt?.angleDegrees == 3.0)
    }

    // MARK: - Test 5: SceneGate settle check

    @Test("SceneGate blocks frame when unsettled")
    func sceneGateBlocksUnsettled() {
        let gate = SceneGate()
        // isSettled starts false; first call should return false
        var buf: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &buf)
        guard let buf else { return }
        #expect(gate.shouldProcess(pixelBuffer: buf) == false)
    }
}
