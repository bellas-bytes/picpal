import Testing
@testable import PicPal

struct CaptureMotionToleranceTests {
    @Test func minorAdjustmentsDoNotNeedASettlingDelay() {
        var motion = CaptureMotionTolerance()
        let initial = motion.update(MotionReading(roll: 0, pitch: 0, timestamp: 1))
        let gentle = motion.update(MotionReading(roll: 0.02, pitch: 0.02, timestamp: 1.1, angularSpeed: 0.3))
        #expect(!initial)
        #expect(gentle)
    }
    @Test func fastMovementPausesAndSlowMovementResumesImmediately() {
        var motion = CaptureMotionTolerance()
        _ = motion.update(MotionReading(roll: 0, pitch: 0, timestamp: 1))
        let fast = motion.update(MotionReading(roll: 0.3, pitch: 0, timestamp: 1.1, angularSpeed: 2))
        let slow = motion.update(MotionReading(roll: 0.31, pitch: 0, timestamp: 1.2, angularSpeed: 0.1))
        #expect(!fast)
        #expect(slow)
    }
    @Test func fastYawIsRejectedEvenWithUnchangedHorizon() {
        var motion = CaptureMotionTolerance()
        _ = motion.update(MotionReading(roll: 0, pitch: 0, timestamp: 1, angularSpeed: 0))
        let pan = motion.update(MotionReading(roll: 0, pitch: 0, timestamp: 1.1, angularSpeed: 2))
        #expect(!pan)
    }
    @Test func staleAndNonfiniteReadingsCannotAuthorizeCapture() {
        var motion = CaptureMotionTolerance()
        _ = motion.update(MotionReading(roll: 0, pitch: 0, timestamp: 1))
        let stale = motion.update(MotionReading(roll: 0, pitch: 0, timestamp: 4))
        let invalid = motion.update(MotionReading(roll: .nan, pitch: 0, timestamp: 4.1))
        #expect(!stale)
        #expect(!invalid)
    }
}
