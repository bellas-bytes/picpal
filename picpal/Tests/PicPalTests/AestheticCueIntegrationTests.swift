import Testing
import os
@testable import PicPal

// MARK: - AestheticCueIntegrationTests

/// End-to-end integration tests for the `AestheticSignal → CueEngine` path.
///
/// Exercises the stateful `CueEngine.process(frame:)` via synthetic `AestheticSignal`s
/// injected directly into `SignalFrame`. No camera, network, or VLMClient involved.
///
/// Complements `VLMOrchestratorTests` by verifying the pure evaluator + engine path
/// from M3-5 wiring.
struct AestheticCueIntegrationTests {

    // MARK: - Helpers

    /// Returns a clean `SignalFrame` with all Tier-0/0.5 signals in a good state,
    /// plus the supplied aesthetic signal.
    private func makeAestheticFrame(_ aesthetic: AestheticSignal) -> SignalFrame {
        SignalFrame(
            timestamp: 1.0,
            tilt: TiltSignal(angleDegrees: 0.0, isLevel: true),
            blur: BlurSignal(sharpnessScore: 100.0, isBlurry: false),
            exposure: ExposureSignal(
                shadowClipFraction: 0.01,
                highlightClipFraction: 0.01,
                level: .ok
            ),
            framing: FramingSignal(subjectBox: nil, hint: .goodFrame),
            body: nil,
            aesthetic: aesthetic
        )
    }

    /// Returns a clean `SignalFrame` with no aesthetic signal and all signals good.
    private func makeCleanFrame() -> SignalFrame {
        SignalFrame(
            timestamp: 1.0,
            tilt: TiltSignal(angleDegrees: 0.0, isLevel: true),
            blur: BlurSignal(sharpnessScore: 100.0, isBlurry: false),
            exposure: ExposureSignal(
                shadowClipFraction: 0.01,
                highlightClipFraction: 0.01,
                level: .ok
            ),
            framing: FramingSignal(subjectBox: nil, hint: .goodFrame),
            body: nil,
            aesthetic: nil
        )
    }

    // MARK: - Test 1: .remark → Cue at .aesthetic priority

    @Test("AestheticSignal(.remark) → CueEvaluator returns Cue at .aesthetic priority with tier2 source")
    func aestheticRemarkProducesCueAtAestheticPriority() {
        let evaluator = CueEvaluator()
        let remarkText = "Step back for a wider shot"
        let signal = AestheticSignal(remark: remarkText, confidence: 1.0, hint: .remark)
        let frame = makeAestheticFrame(signal)

        let cue = evaluator.evaluate(frame: frame)

        #expect(cue != nil)
        #expect(cue?.text == remarkText)
        #expect(cue?.priority == .aesthetic)
        #expect(cue?.sourceTier == .tier2)
    }

    // MARK: - Test 2: .nothingToSay → nil cue

    @Test("AestheticSignal(.nothingToSay) → CueEvaluator returns nil (silence)")
    func aestheticNothingToSayProducesNoCue() {
        let evaluator = CueEvaluator()
        let signal = AestheticSignal.nothingToSay
        let frame = makeAestheticFrame(signal)

        let cue = evaluator.evaluate(frame: frame)

        #expect(cue == nil)
    }

    // MARK: - Test 3: nil aesthetic → nil cue (baseline)

    @Test("nil aesthetic field → CueEvaluator returns nil when all other signals are clean")
    func nilAestheticProducesNilWhenAllSignalsClean() {
        let evaluator = CueEvaluator()
        let frame = makeCleanFrame()

        let cue = evaluator.evaluate(frame: frame)

        #expect(cue == nil)
    }

    // MARK: - Test 4: aesthetic cue flows through CueEngine with correct debounce

    @Test("AestheticSignal(.remark) flows through full CueEngine and respects debounce")
    func aestheticRemarkFlowsThroughCueEngine() {
        let engine = CueEngine(
            cueCooldownSeconds: 3.0,
            minRepeatIntervalSeconds: 5.0
        )
        let remarkText = "Move the subject to the left third"
        let signal = AestheticSignal(remark: remarkText, confidence: 1.0, hint: .remark)
        let frame = makeAestheticFrame(signal)

        // First call — should emit the cue.
        let cue1 = engine.process(frame: frame)
        #expect(cue1?.text == remarkText)
        #expect(cue1?.priority == .aesthetic)

        // Immediate second call — cooldown suppresses it.
        let cue2 = engine.process(frame: frame)
        #expect(cue2 == nil)
    }

    // MARK: - Test 5: aesthetic cue priority (.aesthetic = 4) is lower than body (.body = 3)

    @Test("Body signal outranks aesthetic cue when both are present (body priority 3 < aesthetic 4)")
    func bodySignalOutranksAestheticCue() {
        let evaluator = CueEvaluator()
        let awkwardCropBody = BodySignal(hint: .awkwardCrop, confidence: 0.9, dominantRect: nil)
        let aesthetic = AestheticSignal(remark: "Step left", confidence: 1.0, hint: .remark)

        let frame = SignalFrame(
            timestamp: 1.0,
            tilt: TiltSignal(angleDegrees: 0.0, isLevel: true),
            blur: BlurSignal(sharpnessScore: 100.0, isBlurry: false),
            exposure: ExposureSignal(
                shadowClipFraction: 0.01,
                highlightClipFraction: 0.01,
                level: .ok
            ),
            framing: FramingSignal(subjectBox: nil, hint: .goodFrame),
            body: awkwardCropBody,
            aesthetic: aesthetic
        )

        let cue = evaluator.evaluate(frame: frame)

        // Body cue (priority .body = 3) wins over aesthetic (priority .aesthetic = 4).
        #expect(cue?.priority == .body)
        #expect(cue?.text == CueText.awkwardCrop)
    }

    // MARK: - Test 6: aesthetic accumulated via SignalFrameAccumulator

    @Test("SignalFrameAccumulator.update(aesthetic:) merges aesthetic signal into frame")
    func accumulatorPreservesAestheticAcrossOtherUpdates() {
        // Use a lock-protected array so the @Sendable onFrame closure can mutate it.
        let framesLock = OSAllocatedUnfairLock<[SignalFrame]>(initialState: [])
        let accumulator = SignalFrameAccumulator { frame in
            framesLock.withLock { $0.append(frame) }
        }

        let aesthetic = AestheticSignal(remark: "Tilt the camera slightly", confidence: 1.0, hint: .remark)
        accumulator.update(aesthetic: aesthetic)

        // Update a different signal — aesthetic must be preserved in the new frame.
        let tilt = TiltSignal(angleDegrees: 0.0, isLevel: true)
        accumulator.update(tilt: tilt)

        let received = framesLock.withLock { $0 }
        #expect(received.count == 2)
        // Both frames should carry the aesthetic signal.
        #expect(received[0].aesthetic == aesthetic)
        #expect(received[1].aesthetic == aesthetic)
    }
}
