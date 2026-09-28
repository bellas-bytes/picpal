import Testing
@testable import PicPal

struct AutoCaptureGateTests {
    @Test func startsQuicklyAndRepeatsUntilStopped() {
        var gate = AutoCaptureGate()
        let unarmed = gate.update(isReady: true, now: 0)
        #expect(!unarmed)
        gate.arm()
        let firstFrame = gate.update(isReady: true, now: 0)
        let firstShot = gate.update(isReady: true, now: 0.3)
        #expect(!firstFrame)
        #expect(firstShot)
        #expect(gate.isArmed)
        let tooSoon = gate.update(isReady: true, now: 0.6)
        let nextShot = gate.update(isReady: true, now: 1.2)
        #expect(!tooSoon)
        #expect(nextShot)
        gate.disarm()
        let stopped = gate.update(isReady: true, now: 2)
        #expect(!stopped)
    }

    @Test func lossOfReadinessPausesButDoesNotDisarm() {
        var gate = AutoCaptureGate()
        gate.arm()
        _ = gate.update(isReady: true, now: 0)
        let absent = gate.update(isReady: false, now: 0.2)
        #expect(!absent)
        #expect(gate.isArmed)
        let returned = gate.update(isReady: true, now: 0.3)
        let resumed = gate.update(isReady: true, now: 0.6)
        #expect(!returned)
        #expect(resumed)
    }

    @Test func elapsedGapCannotCountAsFreshReadiness() {
        var gate = AutoCaptureGate()
        gate.arm()
        _ = gate.update(isReady: true, now: 0)
        let afterGap = gate.update(isReady: true, now: 5)
        #expect(!afterGap)
        #expect(gate.progress == 0)
    }
}
