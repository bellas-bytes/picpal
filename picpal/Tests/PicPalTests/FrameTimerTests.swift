import Testing
@testable import PicPal

// MARK: - FrameTimerStatistics

@Suite("FrameTimerStatistics")
struct FrameTimerStatisticsTests {

    @Test("zero has all-zero fields")
    func zeroHasAllZeroFields() {
        let zero = FrameTimerStatistics.zero
        #expect(zero.meanMs == 0)
        #expect(zero.p95Ms == 0)
        #expect(zero.maxMs == 0)
        #expect(zero.dropCount == 0)
    }

    @Test("Equatable: same values are equal")
    func equalityWithSameValues() {
        let a = FrameTimerStatistics(meanMs: 10, p95Ms: 15, maxMs: 20, dropCount: 3)
        let b = FrameTimerStatistics(meanMs: 10, p95Ms: 15, maxMs: 20, dropCount: 3)
        #expect(a == b)
    }

    @Test("Equatable: different dropCount is not equal")
    func inequalityWithDifferentDropCount() {
        let a = FrameTimerStatistics(meanMs: 10, p95Ms: 15, maxMs: 20, dropCount: 0)
        let b = FrameTimerStatistics(meanMs: 10, p95Ms: 15, maxMs: 20, dropCount: 1)
        #expect(a != b)
    }
}

// MARK: - FrameTimer

@Suite("FrameTimer")
struct FrameTimerTests {

    // MARK: - Constants

    @Test("frameTimeBudgetMs is 16.67")
    func frameTimeBudgetConstant() {
        #expect(FrameTimer.frameTimeBudgetMs == 16.67)
    }

    // MARK: - Empty state

    @Test("statistics returns .zero when no samples recorded")
    func statisticsZeroWhenEmpty() async {
        let timer = FrameTimer()
        let stats = await timer.statistics
        #expect(stats == .zero)
    }

    // MARK: - Single sample

    @Test("single sample below budget produces correct statistics")
    func singleSampleBelowBudget() async {
        let timer = FrameTimer()
        await timer.injectSample(ms: 10.0)
        let stats = await timer.statistics
        #expect(stats.meanMs == 10.0)
        #expect(stats.maxMs == 10.0)
        #expect(stats.p95Ms == 10.0)
        #expect(stats.dropCount == 0)
    }

    @Test("sample exceeding budget increments dropCount")
    func sampleOverBudgetIncrementsDrop() async {
        let timer = FrameTimer()
        await timer.injectSample(ms: FrameTimer.frameTimeBudgetMs + 1)
        let stats = await timer.statistics
        #expect(stats.dropCount == 1)
    }

    @Test("sample exactly at budget does not increment dropCount")
    func sampleAtBudgetExactlyNoDrop() async {
        let timer = FrameTimer()
        await timer.injectSample(ms: FrameTimer.frameTimeBudgetMs)
        let stats = await timer.statistics
        #expect(stats.dropCount == 0)
    }

    // MARK: - Aggregates over multiple samples

    @Test("mean is the arithmetic mean of all samples")
    func meanAcrossMultipleSamples() async {
        let timer = FrameTimer()
        await timer.injectSample(ms: 10.0)
        await timer.injectSample(ms: 20.0)
        await timer.injectSample(ms: 30.0)
        let stats = await timer.statistics
        #expect(stats.meanMs == 20.0)
    }

    @Test("max is the largest sample value")
    func maxIsLargestSample() async {
        let timer = FrameTimer()
        await timer.injectSample(ms: 5.0)
        await timer.injectSample(ms: 50.0)
        await timer.injectSample(ms: 25.0)
        let stats = await timer.statistics
        #expect(stats.maxMs == 50.0)
    }

    @Test("p95 is the 95th percentile of sorted samples")
    func p95IsCorrectForTwentySamples() async {
        let timer = FrameTimer()
        // 20 samples: 1.0 … 20.0 (ascending)
        for i in 1...20 {
            await timer.injectSample(ms: Double(i))
        }
        let stats = await timer.statistics
        // ceil(0.95 * 20) - 1 = 18  →  sorted[18] = 19.0
        #expect(stats.p95Ms == 19.0)
    }

    @Test("dropCount accumulates across multiple violations")
    func dropCountAccumulatesAcrossViolations() async {
        let timer = FrameTimer()
        let budget = FrameTimer.frameTimeBudgetMs
        await timer.injectSample(ms: budget + 1)  // drop
        await timer.injectSample(ms: budget - 1)  // ok
        await timer.injectSample(ms: budget + 5)  // drop
        let stats = await timer.statistics
        #expect(stats.dropCount == 2)
    }

    // MARK: - Token / start API

    @Test("start() can be called without await (nonisolated)")
    func startIsNonisolated() {
        let timer = FrameTimer()
        // If this compiles, start() is nonisolated as specified.
        let token = timer.start()
        _ = token  // suppress unused-variable warning
    }
}
