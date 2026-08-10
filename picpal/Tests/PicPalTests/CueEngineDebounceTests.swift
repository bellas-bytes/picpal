import Foundation
import Testing
@testable import PicPal

// MARK: - TestClock

/// A reference-type clock wrapper for use in Swift 6 `@Sendable` closures.
///
/// Swift 6 forbids capturing a `var` in a `@Sendable` closure. Wrapping the
/// mutable date in an `@unchecked Sendable` class lets tests advance time without
/// spawning background threads.
private final class TestClock: @unchecked Sendable {
    var now: Date

    init(_ date: Date = Date(timeIntervalSince1970: 0)) {
        now = date
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

// MARK: - CueEngineDebounceTests

/// Tests for `CueEngine` — debounce, cooldown, repeat suppression, and injectable clock.
struct CueEngineDebounceTests {

    // MARK: - Helpers

    private func tiltFrame(degrees: Double, isLevel: Bool = false) -> SignalFrame {
        SignalFrame(timestamp: 0, tilt: TiltSignal(angleDegrees: degrees, isLevel: isLevel))
    }

    // MARK: - Debounce (cadence cap)

    @Test("Debounce: cue emitted then same frame within cooldown → nil")
    func debounceSupressesCueWithinCooldown() {
        let clock = TestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 3.0,
            minRepeatIntervalSeconds: 5.0,
            clock: { clock.now }
        )
        let frame = tiltFrame(degrees: 5.0)

        // First call — cue should be emitted.
        let cue1 = engine.process(frame: frame)
        #expect(cue1 != nil)

        // Same frame, still within cooldown — should be suppressed.
        clock.advance(by: 1.0)
        let cue2 = engine.process(frame: frame)
        #expect(cue2 == nil)
    }

    @Test("After cooldown expires, cue can fire again if text changed")
    func cueAfterCooldownWithDifferentText() {
        let clock = TestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 2.0,
            minRepeatIntervalSeconds: 10.0,
            clock: { clock.now }
        )

        // Emit a tilt cue.
        let tilt = tiltFrame(degrees: 5.0)
        let cue1 = engine.process(frame: tilt)
        #expect(cue1?.text == CueText.tiltLeft)

        // Advance past cooldown.
        clock.advance(by: 3.0)

        // Different cue text (exposure) — should be emitted.
        let exposure = SignalFrame(
            timestamp: 0,
            exposure: ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .underexposed)
        )
        let cue2 = engine.process(frame: exposure)
        #expect(cue2?.text == CueText.tooDark)
    }

    // MARK: - Repeat suppression

    @Test("Repeat suppression: same cue text blocked within minRepeatInterval")
    func repeatSuppressedWithinMinRepeatInterval() {
        let clock = TestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 1.0,
            minRepeatIntervalSeconds: 5.0,
            clock: { clock.now }
        )
        let frame = tiltFrame(degrees: 5.0)

        // First emission.
        let cue1 = engine.process(frame: frame)
        #expect(cue1?.text == CueText.tiltLeft)

        // Advance past cooldown but not past minRepeat.
        clock.advance(by: 2.0)
        let cue2 = engine.process(frame: frame)
        #expect(cue2 == nil)  // same text, within minRepeat window
    }

    @Test("Repeat suppression: same cue text allowed after minRepeatInterval elapses")
    func repeatAllowedAfterMinRepeatInterval() {
        let clock = TestClock()
        let engine = CueEngine(
            cueCooldownSeconds: 1.0,
            minRepeatIntervalSeconds: 5.0,
            clock: { clock.now }
        )
        let frame = tiltFrame(degrees: 5.0)

        // First emission.
        let cue1 = engine.process(frame: frame)
        #expect(cue1?.text == CueText.tiltLeft)

        // Advance past both cooldown and minRepeat.
        clock.advance(by: 6.0)
        let cue2 = engine.process(frame: frame)
        #expect(cue2?.text == CueText.tiltLeft)  // allowed again
    }

    // MARK: - Good frame emits nil

    @Test("CueEngine passes through nil for good frame (no debounce state change)")
    func engineNilForGoodFrame() {
        let engine = CueEngine()
        let cue = engine.process(frame: .empty)
        #expect(cue == nil)
    }
}
