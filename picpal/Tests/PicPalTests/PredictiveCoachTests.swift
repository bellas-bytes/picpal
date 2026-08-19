import Foundation
import os
import Testing
@testable import PicPal

// MARK: - PredictiveCoach State Machine Tests

@Suite("PredictiveCoach")
struct PredictiveCoachTests {

    typealias Trend = SignalTrendDetector.Trend
    typealias Action = PredictiveCoach.Action

    // MARK: - Idle → waiting → confirmed (threshold crossed while waiting)

    @Test("idle + improving + not threshold → emitPredictiveHint, enters waiting")
    func idleImprovingNotThreshold_emitsPredictiveHint() {
        let coach = PredictiveCoach()
        let action = coach.update(trend: .improving, isWithinThreshold: false)
        #expect(action == .emitPredictiveHint)
    }

    @Test("waiting + threshold crossed → emitPositiveCue, returns to idle")
    func waitingThresholdCrossed_emitsPositiveCue() {
        let clock = MockPredictiveClock()
        let coach = PredictiveCoach(clock: { clock.now() })

        let a1 = coach.update(trend: .improving, isWithinThreshold: false)
        #expect(a1 == .emitPredictiveHint)

        let a2 = coach.update(trend: .stable, isWithinThreshold: true)
        #expect(a2 == .emitPositiveCue)
    }

    @Test("after emitPositiveCue coach is idle — threshold still met → idle not another positive")
    func afterPositiveCue_returnsToIdle() {
        let clock = MockPredictiveClock()
        let coach = PredictiveCoach(clock: { clock.now() })

        coach.update(trend: .improving, isWithinThreshold: false)
        coach.update(trend: .stable, isWithinThreshold: true)  // → .emitPositiveCue
        let a3 = coach.update(trend: .stable, isWithinThreshold: true)
        #expect(a3 == .idle)
    }

    // MARK: - Idle → waiting → silent (within window, still improving)

    @Test("waiting within window + still improving → silent")
    func waitingWithinWindow_silent() {
        let clock = MockPredictiveClock()
        let coach = PredictiveCoach(waitWindowSeconds: 5.0, clock: { clock.now() })

        coach.update(trend: .improving, isWithinThreshold: false)  // → .emitPredictiveHint

        clock.advance(by: 2.0)
        let action = coach.update(trend: .improving, isWithinThreshold: false)
        #expect(action == .silent)
    }

    // MARK: - Idle → waiting → revertToCorrective (timeout)

    @Test("waiting past window + still improving → revertToCorrective")
    func waitingPastWindow_reverts() {
        let clock = MockPredictiveClock()
        let waitWindow = PredictiveCoach.defaultWaitWindowSeconds
        let coach = PredictiveCoach(waitWindowSeconds: waitWindow, clock: { clock.now() })

        coach.update(trend: .improving, isWithinThreshold: false)  // → .emitPredictiveHint

        clock.advance(by: waitWindow + 0.1)
        let action = coach.update(trend: .improving, isWithinThreshold: false)
        #expect(action == .revertToCorrective)
    }

    @Test("after timeout revert, coach is idle")
    func afterTimeoutRevert_isIdle() {
        let clock = MockPredictiveClock()
        let waitWindow = PredictiveCoach.defaultWaitWindowSeconds
        let coach = PredictiveCoach(waitWindowSeconds: waitWindow, clock: { clock.now() })

        coach.update(trend: .improving, isWithinThreshold: false)
        clock.advance(by: waitWindow + 0.1)
        coach.update(trend: .improving, isWithinThreshold: false)  // → .revertToCorrective

        let action = coach.update(trend: .stable, isWithinThreshold: false)
        #expect(action == .idle)
    }

    // MARK: - Idle → waiting → revertToCorrective (trend reversal)

    @Test("waiting + trend worsens → revertToCorrective")
    func waitingTrendWorsens_reverts() {
        let coach = PredictiveCoach()
        coach.update(trend: .improving, isWithinThreshold: false)  // → .emitPredictiveHint
        let action = coach.update(trend: .worsening, isWithinThreshold: false)
        #expect(action == .revertToCorrective)
    }

    @Test("waiting + trend stable + not threshold → revertToCorrective")
    func waitingTrendStableNotThreshold_reverts() {
        let coach = PredictiveCoach()
        coach.update(trend: .improving, isWithinThreshold: false)  // → .emitPredictiveHint
        let action = coach.update(trend: .stable, isWithinThreshold: false)
        #expect(action == .revertToCorrective)
    }

    // MARK: - Idle baseline cases

    @Test("idle + threshold already met → idle (no session started)")
    func idleThresholdAlreadyMet_idle() {
        let coach = PredictiveCoach()
        let action = coach.update(trend: .stable, isWithinThreshold: true)
        #expect(action == .idle)
    }

    @Test("idle + stable + not threshold → idle")
    func idleStableNotThreshold_idle() {
        let coach = PredictiveCoach()
        let action = coach.update(trend: .stable, isWithinThreshold: false)
        #expect(action == .idle)
    }

    // MARK: - defaultWaitWindowSeconds constant

    @Test("defaultWaitWindowSeconds is 2.5")
    func defaultWaitWindowSecondsIs2_5() {
        #expect(PredictiveCoach.defaultWaitWindowSeconds == 2.5)
    }

    // MARK: - Reset

    @Test("reset clears waiting state — next improving frame starts fresh session")
    func reset_clearsWaitingState() {
        let coach = PredictiveCoach()
        coach.update(trend: .improving, isWithinThreshold: false)  // → .emitPredictiveHint (waiting)
        coach.reset()
        let action = coach.update(trend: .improving, isWithinThreshold: false)
        #expect(action == .emitPredictiveHint)
    }

    // MARK: - Concurrent safety

    @Test("concurrent update calls are safe")
    func concurrentUpdateIsSafe() {
        let coach = PredictiveCoach()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let threshold = i % 3 == 0
            let trend: SignalTrendDetector.Trend = i % 2 == 0 ? .improving : .stable
            _ = coach.update(trend: trend, isWithinThreshold: threshold)
        }
        #expect(true)
    }
}

// MARK: - Mock Clock (shared with integration tests via internal access)

final class MockPredictiveClock: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<TimeInterval>

    init(startAt t: TimeInterval = 0) {
        self.lock = OSAllocatedUnfairLock(initialState: t)
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { $0 += interval }
    }

    func now() -> Date {
        Date(timeIntervalSinceReferenceDate: lock.withLock { $0 })
    }
}
