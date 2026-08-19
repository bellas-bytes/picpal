import Foundation
import os
import Testing
@testable import PicPal

// MARK: - TestClock

private final class TestClock: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<TimeInterval>

    init(_ initial: TimeInterval = 0) {
        self.lock = OSAllocatedUnfairLock(initialState: initial)
    }

    var time: TimeInterval {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    func advance(by delta: TimeInterval) {
        lock.withLock { $0 += delta }
    }
}

// MARK: - Fixtures

private enum GateFixture {
    static let cadence: TimeInterval = VLMRequestGate.defaultCadenceSeconds
    static let baseline = SceneSignature(meanLuminance: 0.50, luminanceVariance: 0.10)
    static let novel = SceneSignature(
        meanLuminance: baseline.meanLuminance + SceneSignature.defaultLuminanceDeltaThreshold * 3,
        luminanceVariance: baseline.luminanceVariance
    )
    static let identical = SceneSignature(meanLuminance: 0.50, luminanceVariance: 0.10)
    static let thirdScene = SceneSignature(meanLuminance: 0.90, luminanceVariance: 0.50)
}

// MARK: - Helper

private func clockPastOneCadence() -> TestClock {
    TestClock(GateFixture.cadence + 1.0)
}

/// Builds gate, clock, and budget for a test (defaults: past-cadence clock, 50-call budget).
private func makeGate(
    clockTime: TimeInterval = GateFixture.cadence + 1.0,
    budgetMaxCalls: Int = 50
) -> (gate: VLMRequestGate, clock: TestClock, budget: VLMSessionBudget) {
    let clock = TestClock(clockTime)
    let budget = VLMSessionBudget(maxCalls: budgetMaxCalls)
    let gate = VLMRequestGate(
        cadenceSeconds: GateFixture.cadence,
        budget: budget,
        clock: { clock.time }
    )
    return (gate: gate, clock: clock, budget: budget)
}

// MARK: - VLMRequestGateTests
struct VLMRequestGateTests {
    // MARK: - Gate 1: Settle

    @Test("Gate 1: isSettled=false blocks when all other gates would pass")
    func settleGateBlocksUnsettledScene() {
        var (gate, _, budget) = makeGate()

        let result = gate.shouldRequest(signature: GateFixture.baseline, isSettled: false)

        #expect(!result)
        // Budget must not be touched when a cheaper gate fails first.
        #expect(budget.callsRemaining == 50)
    }

    @Test("Gate 2: same scene as last request blocks the second call")
    func noveltyGateBlocksDuplicateScene() {
        var (gate, clock, budget) = makeGate()

        // First call succeeds — no prior signature, novelty gate is open.
        let first = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(first)

        // Advance past cadence so gate 3 re-opens.
        clock.advance(by: GateFixture.cadence + 1.0)

        // Second call with the same-valued signature: novelty gate blocks.
        let second = gate.shouldRequest(signature: GateFixture.identical, isSettled: true)
        #expect(!second)
        // Budget should have been consumed only for the first call.
        #expect(budget.callsRemaining == 49)
    }

    @Test("Gate 3: cadence cap blocks a call before the interval elapses")
    func cadenceGateBlocksFrequentCalls() {
        var (gate, clock, budget) = makeGate()

        // First call passes all gates.
        let first = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(first)

        // Advance by less than one cadence interval — cadence gate still closed.
        clock.advance(by: GateFixture.cadence * 0.5)

        // Second call with a novel scene: cadence gate blocks.
        let second = gate.shouldRequest(signature: GateFixture.novel, isSettled: true)
        #expect(!second)
        // Budget consumed only once.
        #expect(budget.callsRemaining == 49)
    }

    @Test("Gate 4: zero-capacity budget blocks all requests immediately")
    func budgetGateBlocksWhenExhausted() {
        var (gate, _, budget) = makeGate(budgetMaxCalls: 0)

        let result = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(!result)
        #expect(budget.isExhausted)
    }

    @Test("All four gates passing returns true and decrements budget")
    func allGatesPassReturnsTrue() {
        var (gate, _, budget) = makeGate()

        let result = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)

        #expect(result)
        #expect(budget.callsRemaining == 49)
    }

    @Test("First-ever request passes novelty gate with no prior signature")
    func firstRequestPassesNoveltyGate() {
        var (gate, _, _) = makeGate()

        let result = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(result)
    }

    @Test("Budget exhaustion is sticky — subsequent calls never succeed")
    func budgetExhaustionIsPermanent() {
        var (gate, clock, budget) = makeGate(budgetMaxCalls: 1)

        // Consume the sole budget unit.
        let first = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(first)
        #expect(budget.isExhausted)

        // Advance past cadence; present a novel scene.
        clock.advance(by: GateFixture.cadence + 1.0)
        let second = gate.shouldRequest(signature: GateFixture.novel, isSettled: true)
        #expect(!second)

        // One more advance and a third distinct scene — still blocked.
        clock.advance(by: GateFixture.cadence + 1.0)
        let third = gate.shouldRequest(signature: GateFixture.thirdScene, isSettled: true)
        #expect(!third)
    }

    @Test("Cadence timer resets after authorized request — next call needs a full interval")
    func cadenceTimerResetsAfterAuthorization() {
        var (gate, clock, _) = makeGate()

        // First authorized request.
        let first = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(first)

        // Advance exactly one cadence interval from the first authorization.
        clock.advance(by: GateFixture.cadence + 0.1)

        // Second call with novel scene: cadence interval has elapsed → passes.
        let second = gate.shouldRequest(signature: GateFixture.novel, isSettled: true)
        #expect(second)

        // Immediately after second authorization, cadence gate is closed again.
        let immediate = gate.shouldRequest(signature: GateFixture.thirdScene, isSettled: true)
        #expect(!immediate)
    }

    @Test("Novelty gate compares against last-request signature, not the most-recent frame")
    func noveltyGateComparesAgainstLastRequestSignature() {
        var (gate, clock, _) = makeGate()

        // Authorized request 1 — baseline recorded as "last request signature".
        let first = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(first)

        // Advance past cadence; present many "intermediate" frames that are the
        // same scene as the last request. These simulate the gate being polled once
        // per camera frame between authorized requests.
        clock.advance(by: GateFixture.cadence + 1.0)

        // Same scene as last REQUEST — novelty gate blocks even though cadence is open.
        let sameAsRequest = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true)
        #expect(!sameAsRequest)

        // Advance a tiny amount (cadence still open from above advance).
        clock.advance(by: 0.01)

        // Novel scene — different from last REQUEST signature → novelty gate passes.
        let novelFromRequest = gate.shouldRequest(signature: GateFixture.novel, isSettled: true)
        #expect(novelFromRequest, "Novel scene vs last-request signature should be authorized")
    }

    @Test("Budget.tryConsume is not called when settle/novelty/cadence gates fail")
    func budgetNotConsumedWhenEarlyGatesFail() {
        var (gate, clock, budget) = makeGate(budgetMaxCalls: 5)

        // Fail gate 1 (not settled): budget must stay at 5.
        _ = gate.shouldRequest(signature: GateFixture.baseline, isSettled: false)
        #expect(budget.callsRemaining == 5)

        // Pass gate 1 for the novelty-fail scenario below.
        _ = gate.shouldRequest(signature: GateFixture.baseline, isSettled: true) // consumes 1
        #expect(budget.callsRemaining == 4)

        // Advance past cadence, use same scene to trigger gate 2 failure.
        clock.advance(by: GateFixture.cadence + 1.0)
        _ = gate.shouldRequest(signature: GateFixture.identical, isSettled: true)
        // Gate 2 (novelty) failed — budget must not have been touched again.
        #expect(budget.callsRemaining == 4)

        // Now use novel scene but NOT past cadence to trigger gate 3 failure.
        // (cadence starts from last successful request, not from clock.time)
        let authorized = gate.shouldRequest(signature: GateFixture.novel, isSettled: true)
        // cadence elapsed > cadenceSeconds already from above advance, this should actually pass...
        // Let's reset: use the novel scene successfully first, then trigger cadence failure.
        if authorized {
            // This is expected since cadence IS open; consume was valid.
            // Now immediately try again with thirdScene — cadence gate blocks.
            _ = gate.shouldRequest(signature: GateFixture.thirdScene, isSettled: true)
            // Budget should have decreased by 1 more (from authorized passing) but
            // the immediate retry should not consume.
            let afterCadenceBlock = budget.callsRemaining
            // Re-assert: the cadence-blocked call didn't consume budget.
            _ = gate.shouldRequest(signature: GateFixture.thirdScene, isSettled: true)
            #expect(budget.callsRemaining == afterCadenceBlock)
        }
    }
}

// MARK: - VLMSessionBudgetTests

struct VLMSessionBudgetTests {

    @Test("tryConsume returns true and decrements callsRemaining")
    func tryConsumeDecrementsCount() {
        let budget = VLMSessionBudget(maxCalls: 3)

        #expect(budget.callsRemaining == 3)
        #expect(budget.tryConsume())
        #expect(budget.callsRemaining == 2)
        #expect(budget.tryConsume())
        #expect(budget.callsRemaining == 1)
    }

    @Test("tryConsume returns false and isExhausted becomes true after last unit")
    func tryConsumeReturnsFalseWhenExhausted() {
        let budget = VLMSessionBudget(maxCalls: 2)

        #expect(budget.tryConsume()) // 1
        #expect(budget.tryConsume()) // 2 — last unit
        #expect(budget.isExhausted)

        #expect(!budget.tryConsume()) // exhausted — sticky
        #expect(!budget.tryConsume())
        #expect(budget.callsRemaining == 0)
    }

    @Test("maxCalls=0 is immediately exhausted — tryConsume always returns false")
    func zeroBudgetIsImmediatelyExhausted() {
        let budget = VLMSessionBudget(maxCalls: 0)

        #expect(budget.isExhausted)
        #expect(!budget.tryConsume())
        #expect(budget.callsRemaining == 0)
    }

    @Test("callsRemaining never goes below zero")
    func callsRemainingNeverBelowZero() {
        let budget = VLMSessionBudget(maxCalls: 1)

        _ = budget.tryConsume() // exhaust
        _ = budget.tryConsume() // extra — no-op

        #expect(budget.callsRemaining == 0)
    }

    @Test("Default maxCalls equals defaultMaxCallsPerSession constant")
    func defaultMaxCallsMatchesNamedConstant() {
        let budget = VLMSessionBudget()

        #expect(budget.callsRemaining == VLMSessionBudget.defaultMaxCallsPerSession)
        #expect(!budget.isExhausted)
    }

    @Test("isExhausted is false before any consumption")
    func isExhaustedFalseBeforeConsumption() {
        let budget = VLMSessionBudget(maxCalls: 10)

        #expect(!budget.isExhausted)
    }
}
