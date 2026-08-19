import Testing
import Foundation
@testable import PicPal

// MARK: - Helpers

private func makeEvent(
    tier: CueSourceTier = .tier0,
    latency: Double? = nil,
    text: String = "Test cue",
    timestamp: Date = Date()
) -> CueEvent {
    CueEvent(timestamp: timestamp, text: text, tier: tier, latencyFromSettleMs: latency)
}

// MARK: - CueLoggerTests

@Suite("CueLogger")
struct CueLoggerTests {

    // MARK: - Basic recording

    @Test("record_storesEvent: single recorded event is returned by events()")
    func record_storesEvent() {
        let logger = CueLogger()
        let event = makeEvent()
        logger.record(event)
        let stored = logger.events()
        #expect(stored.count == 1)
        #expect(stored[0] == event)
    }

    // MARK: - Ring buffer

    @Test("record_ringBuffer_dropsOldestAtCap: oldest event is evicted when buffer is full")
    func record_ringBuffer_dropsOldestAtCap() {
        let logger = CueLogger()
        let cap = CueLogger.maxEventCount

        // Record cap + 1 events, each with a unique text so we can identify them.
        for i in 0...cap {
            logger.record(makeEvent(text: "cue-\(i)"))
        }

        let stored = logger.events()
        #expect(stored.count == cap)
        // The first-added event ("cue-0") should have been evicted.
        // The new first event should be "cue-1".
        #expect(stored[0].text == "cue-1")
    }

    // MARK: - makeSummary: tier counts

    @Test("makeSummary_tierCounts_correct: counts are split correctly by tier")
    func makeSummary_tierCounts_correct() {
        let logger = CueLogger()
        logger.record(makeEvent(tier: .tier0))
        logger.record(makeEvent(tier: .tier0))
        logger.record(makeEvent(tier: .tier05))
        logger.record(makeEvent(tier: .tier2))

        let report = logger.makeSummary()
        #expect(report.totalCues == 4)
        #expect(report.tier0Count == 2)
        #expect(report.tier05Count == 1)
        #expect(report.tier2Count == 1)
    }

    // MARK: - makeSummary: percentiles with no latency

    @Test("makeSummary_noLatency_returnsNilPercentiles: median and p95 are nil when all events lack latency")
    func makeSummary_noLatency_returnsNilPercentiles() {
        let logger = CueLogger()
        logger.record(makeEvent(latency: nil))
        logger.record(makeEvent(latency: nil))

        let report = logger.makeSummary()
        #expect(report.medianSettleLatencyMs == nil)
        #expect(report.p95SettleLatencyMs == nil)
    }

    // MARK: - makeSummary: median

    @Test("makeSummary_medianCorrect: median of [10, 20, 30] is 20")
    func makeSummary_medianCorrect() {
        let logger = CueLogger()
        logger.record(makeEvent(latency: 10))
        logger.record(makeEvent(latency: 20))
        logger.record(makeEvent(latency: 30))

        let report = logger.makeSummary()
        #expect(report.medianSettleLatencyMs == 20)
    }

    // MARK: - makeSummary: p95 threshold

    @Test("makeSummary_p95_nilBeforeThreshold: p95 is nil for fewer than minSamplesForPercentile samples")
    func makeSummary_p95_nilBeforeThreshold() {
        let logger = CueLogger()
        // 4 samples — one below the threshold of 5.
        for ms in [10.0, 20.0, 30.0, 40.0] {
            logger.record(makeEvent(latency: ms))
        }

        let report = logger.makeSummary()
        #expect(report.p95SettleLatencyMs == nil)
    }

    @Test("makeSummary_p95_presentAtThreshold: p95 is non-nil at exactly minSamplesForPercentile samples")
    func makeSummary_p95_presentAtThreshold() {
        let logger = CueLogger()
        // Exactly 5 samples — meets the threshold.
        for ms in [10.0, 20.0, 30.0, 40.0, 50.0] {
            logger.record(makeEvent(latency: ms))
        }

        let report = logger.makeSummary()
        #expect(report.p95SettleLatencyMs != nil)
    }
}
