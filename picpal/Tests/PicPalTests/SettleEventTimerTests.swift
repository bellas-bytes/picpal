import Testing
import Foundation
@testable import PicPal

// MARK: - Helpers

/// A reference-type container for a mutable value, safe to share across `@Sendable`
/// closures in tests because each test constructs its own instance without data races.
private final class MutableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite("SettleEventTimer")
struct SettleEventTimerTests {

    // MARK: - latencyMs_nilBeforeSettle

    @Test("latencyMs_nilBeforeSettle: returns nil when no settle has been recorded")
    func latencyMs_nilBeforeSettle() {
        let timer = SettleEventTimer()
        #expect(timer.latencyMilliseconds(cueAt: Date()) == nil)
    }

    // MARK: - latencyMs_computedFromSettle

    @Test("latencyMs_computedFromSettle: computes latency from settle to cue within 5 ms tolerance")
    func latencyMs_computedFromSettle() {
        let timer = SettleEventTimer()
        timer.recordSettle()
        // Pretend 100 ms have elapsed by creating the cueAt timestamp manually.
        let cueAt = Date().addingTimeInterval(0.1)
        let latency = timer.latencyMilliseconds(cueAt: cueAt)
        guard let latency else {
            Issue.record("Expected a non-nil latency value")
            return
        }
        #expect(abs(latency - 100.0) < 5.0)
    }

    // MARK: - latencyMs_nilWhenCueBeforeSettle

    @Test("latencyMs_nilWhenCueBeforeSettle: returns nil when cueAt is before the settle time")
    func latencyMs_nilWhenCueBeforeSettle() {
        let settleBox = MutableBox(Date())
        let timer = SettleEventTimer(clock: { settleBox.value })
        timer.recordSettle()

        // cueAt is 100 ms before settle — delta is negative → nil
        let cueAt = settleBox.value.addingTimeInterval(-0.1)
        #expect(timer.latencyMilliseconds(cueAt: cueAt) == nil)
    }

    // MARK: - reset_clearsSettle

    @Test("reset_clearsSettle: latencyMs returns nil after reset even if settle was recorded")
    func reset_clearsSettle() {
        let timer = SettleEventTimer()
        timer.recordSettle()
        timer.reset()
        #expect(timer.latencyMilliseconds(cueAt: Date()) == nil)
    }

    // MARK: - injectableClock_controlsTime

    @Test("injectableClock_controlsTime: injectable clock produces exact millisecond values")
    func injectableClock_controlsTime() {
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let currentBox = MutableBox(base)

        let timer = SettleEventTimer(clock: { currentBox.value })

        // Record settle at t = base
        timer.recordSettle()

        // Advance clock by exactly 250 ms
        currentBox.value = base.addingTimeInterval(0.25)
        let latency = timer.latencyMilliseconds(cueAt: currentBox.value)

        #expect(latency == 250.0)
    }
}
