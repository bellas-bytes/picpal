import Testing
@testable import PicPal

// MARK: - ExposureBiasTests

/// Tests for the manual EV bias state tracking in `CameraCapture`.
///
/// `videoDevice` is nil in unit tests (no physical camera), so `setExposureBias`
/// updates `exposureBiasIsManual` and exits early — no AVCaptureDevice mock needed.
struct ExposureBiasTests {

    // MARK: - exposureBiasIsManual

    @Test func initiallyNotManual() {
        let camera = CameraCapture()
        #expect(camera.exposureBiasIsManual == false)
    }

    @Test func nonZeroBiasSetsManuaTrue() {
        let camera = CameraCapture()
        camera.setExposureBias(1.0)
        #expect(camera.exposureBiasIsManual == true)
    }

    @Test func zeroBiasResetsManualFalse() {
        let camera = CameraCapture()
        camera.setExposureBias(1.0)
        camera.setExposureBias(0.0)
        #expect(camera.exposureBiasIsManual == false)
    }

    @Test func negativeBiasAlsoSetsManualTrue() {
        let camera = CameraCapture()
        camera.setExposureBias(-1.5)
        #expect(camera.exposureBiasIsManual == true)
    }

    @Test func smallPositiveBiasIsManual() {
        let camera = CameraCapture()
        camera.setExposureBias(0.001)
        #expect(camera.exposureBiasIsManual == true)
    }

    // MARK: - CueEngine.suppressExposureCue

    @Test func suppressExposureCueDefaultsFalse() {
        let engine = CueEngine()
        #expect(engine.suppressExposureCue == false)
    }

    @Test func suppressExposureCueRoundtripsTrue() {
        let engine = CueEngine()
        engine.suppressExposureCue = true
        #expect(engine.suppressExposureCue == true)
    }

    @Test func suppressExposureCueRoundtripsFalse() {
        let engine = CueEngine()
        engine.suppressExposureCue = true
        engine.suppressExposureCue = false
        #expect(engine.suppressExposureCue == false)
    }

    // MARK: - Suppression integration with CueEvaluator

    @Test func evaluatorSkipsExposureCueWhenSuppressed() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .underexposed)
        )
        // Without suppression — cue fires.
        let normalCue = evaluator.evaluate(frame: frame, predictive: .noAction, suppressExposureCue: false)
        #expect(normalCue?.text == CueText.tooDark)

        // With suppression — cue is silent.
        let suppressedCue = evaluator.evaluate(frame: frame, predictive: .noAction, suppressExposureCue: true)
        #expect(suppressedCue == nil)
    }

    @Test func evaluatorSkipsOverexposedCueWhenSuppressed() {
        let evaluator = CueEvaluator()
        let frame = SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .overexposed)
        )
        let suppressedCue = evaluator.evaluate(frame: frame, predictive: .noAction, suppressExposureCue: true)
        #expect(suppressedCue == nil)
    }
}
