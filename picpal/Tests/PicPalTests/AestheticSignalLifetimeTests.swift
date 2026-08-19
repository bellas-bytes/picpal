import Foundation
import Testing
import os
@testable import PicPal

// MARK: - TestClock (local)

/// Reference-type clock wrapper that lets tests advance time synchronously.
///
/// `@unchecked Sendable` so it can be captured in `@Sendable` closures without
/// spawning background threads.  Pattern established in `CueEngineDebounceTests`.
private final class LifetimeTestClock: @unchecked Sendable {
    var now: Date

    init(_ date: Date = Date(timeIntervalSince1970: 0)) {
        now = date
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

// MARK: - Constants

/// Mirror of the ContentView-private constant — computed from the same formula.
private let aestheticExpiryTestSeconds = CueEngine.defaultMinRepeatIntervalSeconds + 1.0

// MARK: - AestheticSignalLifetimeTests

/// Tests for the accumulator + cue-engine side of `AestheticSignal` auto-expiry.
///
/// These tests verify the underlying `SignalFrameAccumulator` and `CueEngine` behaviour
/// that the ContentView expiry `Task` relies on.  The actual `Task.sleep` lifecycle
/// lives in ContentView and requires UI testing; the pure engine path is covered here.
struct AestheticSignalLifetimeTests {

    // MARK: - Helpers

    /// Clean `SignalFrame` with all Tier-0 signals in a good state and the given aesthetic.
    private func makeAestheticFrame(_ aesthetic: AestheticSignal?) -> SignalFrame {
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
            aesthetic: aesthetic
        )
    }

    // MARK: - Test 1

    @Test("remark signal clears engine output after accum is cleared with .nothingToSay")
    func remark_expiresAfterDelay() {
        let clock = LifetimeTestClock()
        // Zero cooldown so successive process() calls are not gated.
        let engine = CueEngine(
            cueCooldownSeconds: 0.0,
            minRepeatIntervalSeconds: aestheticExpiryTestSeconds,
            clock: { clock.now }
        )
        let framesLock = OSAllocatedUnfairLock<[SignalFrame]>(initialState: [])
        let accum = SignalFrameAccumulator { frame in
            framesLock.withLock { $0.append(frame) }
        }

        // Drive a .remark signal through the accumulator.
        let remark = AestheticSignal(remark: "Nice composition", confidence: 1.0, hint: .remark)
        accum.update(aesthetic: remark)

        let frameWithRemark = framesLock.withLock { $0.last! }
        let cue1 = engine.process(frame: frameWithRemark)
        #expect(cue1?.text == "Nice composition", "Remark should produce an aesthetic cue")

        // Advance the injected clock past aestheticExpiryTestSeconds.
        clock.advance(by: aestheticExpiryTestSeconds + 0.5)

        // Simulate the ContentView expiry Task firing: clear the accumulator.
        accum.update(aesthetic: AestheticSignal.nothingToSay)

        let clearedFrame = framesLock.withLock { $0.last! }
        let cue2 = engine.process(frame: clearedFrame)
        #expect(cue2 == nil, "Engine should return nil after .nothingToSay clears the aesthetic")
    }

    // MARK: - Test 2

    @Test("nothingToSay signal produces no aesthetic cue in any subsequent frame")
    func nothingToSay_doesNotScheduleExpiry() {
        let clock = LifetimeTestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 0.0,
            minRepeatIntervalSeconds: CueEngine.defaultMinRepeatIntervalSeconds,
            clock: { clock.now }
        )
        let framesLock = OSAllocatedUnfairLock<[SignalFrame]>(initialState: [])
        let accum = SignalFrameAccumulator { frame in
            framesLock.withLock { $0.append(frame) }
        }

        // Drive a .nothingToSay signal — engine must stay silent.
        accum.update(aesthetic: AestheticSignal.nothingToSay)

        let frame = framesLock.withLock { $0.last! }
        let cue1 = engine.process(frame: frame)
        #expect(cue1 == nil, ".nothingToSay should never produce an aesthetic cue")

        // Advance time well past the repeat interval — still no cue.
        clock.advance(by: CueEngine.defaultMinRepeatIntervalSeconds + 1.0)
        let cue2 = engine.process(frame: frame)
        #expect(cue2 == nil, "No cue should appear even after time advances")
    }

    // MARK: - Test 3

    @Test("Second remark overrides first; after second expiry fires, signal is clear")
    func newRemarkCancelsOldExpiry_conceptually() {
        let clock = LifetimeTestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 0.0,
            minRepeatIntervalSeconds: aestheticExpiryTestSeconds,
            clock: { clock.now }
        )
        let framesLock = OSAllocatedUnfairLock<[SignalFrame]>(initialState: [])
        let accum = SignalFrameAccumulator { frame in
            framesLock.withLock { $0.append(frame) }
        }

        // First remark arrives.
        let remark1 = AestheticSignal(remark: "Move left", confidence: 1.0, hint: .remark)
        accum.update(aesthetic: remark1)
        let frame1 = framesLock.withLock { $0.last! }
        let cue1 = engine.process(frame: frame1)
        #expect(cue1?.text == "Move left", "First remark should be emitted")

        // Second remark arrives before the first expiry fires — simulates the first
        // expiry Task being cancelled and a new one being scheduled.
        clock.advance(by: 0.5)  // well within aestheticExpiryTestSeconds
        let remark2 = AestheticSignal(remark: "Step back", confidence: 1.0, hint: .remark)
        accum.update(aesthetic: remark2)
        let frame2 = framesLock.withLock { $0.last! }
        let cue2 = engine.process(frame: frame2)
        #expect(cue2?.text == "Step back", "Second remark should become the active cue")

        // Advance past the second expiry window and fire the clear.
        clock.advance(by: aestheticExpiryTestSeconds + 0.5)
        accum.update(aesthetic: AestheticSignal.nothingToSay)
        let clearedFrame = framesLock.withLock { $0.last! }
        let cue3 = engine.process(frame: clearedFrame)
        #expect(cue3 == nil, "Signal should be silent after second expiry clears the accumulator")
    }
}
