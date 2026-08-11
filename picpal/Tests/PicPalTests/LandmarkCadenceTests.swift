import CoreVideo
import os
import Testing
@testable import PicPal

// MARK: - Clock wrapper

/// Thread-safe mutable clock for deterministic cadence testing.
///
/// `OSAllocatedUnfairLock` makes the wrapper `@Sendable`-safe so it can be
/// captured by the `@Sendable () -> TimeInterval` clock closure required by
/// `LandmarkCadenceController` under Swift 6 strict concurrency.
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

private enum CadenceFixture {
    /// Simulated camera interval for a 30 fps stream (seconds).
    static let cameraInterval: TimeInterval = 1.0 / 30.0
    /// Minimum interval enforced by the default 5 fps cap (seconds).
    static let minLandmarkInterval: TimeInterval =
        1.0 / LandmarkCadenceController.defaultMaxLandmarkFPS
    /// Number of simulated frames to drive through the controller per burst test.
    static let burstFrameCount: Int = 30
}

// MARK: - Pixel buffer helper

/// Creates a minimal 64×64 YCbCr 4:2:0 pixel buffer.
/// Tests need a valid `CVPixelBuffer`; actual content is irrelevant.
private func makeTestPixelBuffer() -> CVPixelBuffer? {
    var buf: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, 64, 64,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        nil,
        &buf
    )
    return buf
}

// MARK: - Presence stubs

private let alwaysPresentResult = PresenceResult(
    personPresent: true,
    dominantRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
)

/// Stub presence checker: always reports a person present.
private let alwaysPresentChecker: @Sendable (CVPixelBuffer) -> PresenceResult = { _ in
    alwaysPresentResult
}

/// Stub presence checker: never detects a person.
private let neverPresentChecker: @Sendable (CVPixelBuffer) -> PresenceResult = { _ in
    .absent
}

// MARK: - LandmarkCadenceTests

/// Swift Testing suite for `LandmarkCadenceController`.
///
/// All tests inject a deterministic `TestClock` and/or a stub presence checker
/// so that gate logic can be verified without Vision or AVFoundation.
struct LandmarkCadenceTests {

    // MARK: - Test 1: Cadence cap

    @Test("30 fps input produces ≤5 approvals per simulated second")
    func cadenceCapLimitsApprovalsToMaxFPS() {
        guard let buf = makeTestPixelBuffer() else {
            Issue.record("Could not create pixel buffer")
            return
        }

        let clock = TestClock()
        let controller = LandmarkCadenceController(
            presenceChecker: alwaysPresentChecker,
            clock: { clock.time }
        )

        var approvalCount = 0
        for _ in 0..<CadenceFixture.burstFrameCount {
            if controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true) {
                approvalCount += 1
            }
            clock.advance(by: CadenceFixture.cameraInterval)
        }

        // In one simulated second at 30 fps, no more than 5 approvals may occur.
        #expect(approvalCount <= Int(LandmarkCadenceController.defaultMaxLandmarkFPS))
    }

    // MARK: - Test 2: Settle gate

    @Test("isSettled false always returns false regardless of presence")
    func settleGateBlocksWhenNotSettled() {
        guard let buf = makeTestPixelBuffer() else {
            Issue.record("Could not create pixel buffer")
            return
        }

        // Start time well past one cadence interval so the cadence gate is open.
        let clock = TestClock(CadenceFixture.minLandmarkInterval + 1.0)
        let controller = LandmarkCadenceController(
            presenceChecker: alwaysPresentChecker,
            clock: { clock.time }
        )

        let result = controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: false)
        #expect(!result)
    }

    // MARK: - Test 3: Presence gate

    @Test("No-person frame returns false even when settled and cadence is open")
    func presenceGateBlocksWhenNoPerson() {
        guard let buf = makeTestPixelBuffer() else {
            Issue.record("Could not create pixel buffer")
            return
        }

        let clock = TestClock(CadenceFixture.minLandmarkInterval + 1.0)
        let controller = LandmarkCadenceController(
            presenceChecker: neverPresentChecker,
            clock: { clock.time }
        )

        let result = controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true)
        #expect(!result)
    }

    // MARK: - Test 4: All gates pass

    @Test("Person present + settled + cadence open returns true")
    func allGatesPassReturnsTrue() {
        guard let buf = makeTestPixelBuffer() else {
            Issue.record("Could not create pixel buffer")
            return
        }

        let clock = TestClock(CadenceFixture.minLandmarkInterval + 1.0)
        let controller = LandmarkCadenceController(
            presenceChecker: alwaysPresentChecker,
            clock: { clock.time }
        )

        let result = controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true)
        #expect(result)
    }

    // MARK: - Test 5: lastPresenceResult

    @Test("lastPresenceResult is updated only after an approved frame")
    func lastPresenceResultReflectsMostRecentApproval() {
        guard let buf = makeTestPixelBuffer() else {
            Issue.record("Could not create pixel buffer")
            return
        }

        let expectedRect = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let customChecker: @Sendable (CVPixelBuffer) -> PresenceResult = { _ in
            PresenceResult(personPresent: true, dominantRect: expectedRect)
        }

        let clock = TestClock(CadenceFixture.minLandmarkInterval + 1.0)
        let controller = LandmarkCadenceController(
            presenceChecker: customChecker,
            clock: { clock.time }
        )

        // Before any approval, lastPresenceResult reports no person.
        #expect(!controller.lastPresenceResult.personPresent)

        // Approve one frame.
        let approved = controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true)
        #expect(approved)

        // lastPresenceResult now reflects the approved frame.
        let stored = controller.lastPresenceResult
        #expect(stored.personPresent)
        #expect(stored.dominantRect == expectedRect)
    }

    // MARK: - Test 6: Injectable clock

    @Test("Injectable clock enables deterministic cadence verification")
    func injectableClockAllowsDeterministicTesting() {
        guard let buf = makeTestPixelBuffer() else {
            Issue.record("Could not create pixel buffer")
            return
        }

        let clock = TestClock(0)
        let controller = LandmarkCadenceController(
            presenceChecker: alwaysPresentChecker,
            clock: { clock.time }
        )

        // At t=0 the cadence interval has not elapsed — should be blocked.
        let firstAttempt = controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true)
        #expect(!firstAttempt)

        // Advance to exactly the minimum interval — gate should open.
        clock.time = CadenceFixture.minLandmarkInterval
        let secondAttempt = controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true)
        #expect(secondAttempt)

        // Advance by less than one interval — gate should close again.
        clock.advance(by: CadenceFixture.cameraInterval)
        let thirdAttempt = controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true)
        #expect(!thirdAttempt)
    }

    // MARK: - Test 7: Tier-0 advisory contract

    @Test("Controller is advisory: approvals per second never exceed the FPS cap")
    func tier0FrameDeliveryIsNotGatedByController() {
        guard let buf = makeTestPixelBuffer() else {
            Issue.record("Could not create pixel buffer")
            return
        }

        let clock = TestClock(0)
        let controller = LandmarkCadenceController(
            presenceChecker: alwaysPresentChecker,
            clock: { clock.time }
        )

        // Drive 30 frames at 30 fps — one simulated second.
        var approvalCount = 0
        for _ in 0..<CadenceFixture.burstFrameCount {
            if controller.shouldRunLandmarks(pixelBuffer: buf, isSettled: true) {
                approvalCount += 1
            }
            clock.advance(by: CadenceFixture.cameraInterval)
        }

        // Frame delivery (30 fps) is never gated; only approvals are throttled.
        let maxAllowed = Int(LandmarkCadenceController.defaultMaxLandmarkFPS)
        #expect(approvalCount <= maxAllowed)
        // Sanity check: at least one frame was approved.
        #expect(approvalCount > 0)
    }
}
