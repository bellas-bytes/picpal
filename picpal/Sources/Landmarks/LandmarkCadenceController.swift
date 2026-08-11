import CoreVideo
import Foundation
import os

// MARK: - Private state snapshot

private struct CadenceState {
    /// Timestamp of the last frame for which `shouldRunLandmarks` returned `true`.
    var lastApprovalTime: TimeInterval
    /// Presence result from the most recent approved frame.
    var lastPresenceResult: PresenceResult

    static let initial = CadenceState(
        lastApprovalTime: 0,
        lastPresenceResult: .absent
    )
}

// MARK: - LandmarkCadenceController

/// Thread-safe rate limiter that enforces the ≤5 fps landmark cadence plus
/// the settle and presence gates.
///
/// ## Gate order (cheapest-first — short-circuit on first failure)
/// 1. **Cadence cap** — compares timestamps; no Vision work.
/// 2. **Settle flag** — boolean passed in by the caller.
/// 3. **Presence** — runs `VNDetectHumanRectanglesRequest` via `PresenceGate`.
///
/// ## Tier-0 safety
/// The controller is **advisory**: it does not block camera frame delivery.
/// Callers decide whether to run landmark models based on the returned `Bool`.
///
/// ## Thread safety
/// All mutable state is guarded by `OSAllocatedUnfairLock`. The injectable
/// clock mirrors the pattern from `SignalFrameAccumulator`.
public final class LandmarkCadenceController: @unchecked Sendable {

    // MARK: - Constants

    /// Maximum landmark inference rate regardless of camera FPS.
    /// Raising this cap is a one-line change here — no refactor required.
    public static let defaultMaxLandmarkFPS: Double = 5.0

    // MARK: - Private helpers

    private enum ControllerConstants {
        static func minInterval(forFPS fps: Double) -> TimeInterval { 1.0 / fps }
    }

    // MARK: - Dependencies

    private let minInterval: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let presenceChecker: @Sendable (CVPixelBuffer) -> PresenceResult

    // MARK: - Protected state

    private let lock: OSAllocatedUnfairLock<CadenceState>

    private let logger = Logger(subsystem: "com.picpal", category: "LandmarkCadenceController")

    // MARK: - Public init

    /// Creates a `LandmarkCadenceController` backed by a real `PresenceGate`.
    ///
    /// - Parameters:
    ///   - maxFPS: Landmark inference cap. Change `defaultMaxLandmarkFPS` to
    ///     adjust globally; pass a custom value to override locally.
    ///   - clock: Returns the current time as a `TimeInterval`. Defaults to
    ///     `Date().timeIntervalSince1970`. Injectable for deterministic testing.
    public convenience init(
        maxFPS: Double = LandmarkCadenceController.defaultMaxLandmarkFPS,
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        let gate = PresenceGate()
        self.init(
            maxFPS: maxFPS,
            presenceChecker: { gate.check(pixelBuffer: $0) },
            clock: clock
        )
    }

    // MARK: - Internal init (test seam)

    /// Creates a `LandmarkCadenceController` with an injectable presence checker.
    ///
    /// Accessible via `@testable import PicPal`. Not part of the public API.
    ///
    /// - Parameters:
    ///   - maxFPS: Landmark inference cap.
    ///   - presenceChecker: Closure that runs presence detection. Tests supply
    ///     a deterministic stub; production uses `PresenceGate.check`.
    ///   - clock: Deterministic clock for cadence tests.
    init(
        maxFPS: Double = LandmarkCadenceController.defaultMaxLandmarkFPS,
        presenceChecker: @escaping @Sendable (CVPixelBuffer) -> PresenceResult,
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.minInterval = ControllerConstants.minInterval(forFPS: maxFPS)
        self.clock = clock
        self.presenceChecker = presenceChecker
        self.lock = OSAllocatedUnfairLock(initialState: .initial)
    }

    // MARK: - Public API

    /// Returns `true` if a landmark inference pass should run for this frame.
    ///
    /// All three gates must pass. Short-circuits cheapest-first.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The current camera frame.
    ///   - isSettled: The current settle state from `SceneGate` / `TiltMonitor`.
    /// - Returns: `true` when cadence, settle, and presence gates all pass.
    public func shouldRunLandmarks(pixelBuffer: CVPixelBuffer, isSettled: Bool) -> Bool {
        let now = clock()

        // Gate 1: Cadence cap — no Vision work, just a timestamp compare.
        let elapsed = now - lock.withLock { $0.lastApprovalTime }
        guard elapsed >= minInterval else {
            return false
        }

        // Gate 2: Settle flag — cheap boolean supplied by the caller.
        guard isSettled else {
            return false
        }

        // Gate 3: Presence detection — most expensive; runs VNDetectHumanRectanglesRequest.
        let result = presenceChecker(pixelBuffer)

        // Always record the latest presence result so the orchestrator's reset path
        // can fire when the subject leaves frame (C1 fix: was only written when present).
        lock.withLock { $0.lastPresenceResult = result }

        guard result.personPresent else {
            return false
        }

        // Person confirmed — record approval time.
        lock.withLock { $0.lastApprovalTime = now }

        return true
    }

    // MARK: - Split-gate API (used by LandmarkOrchestrator for I2 fix)

    /// Cheap cadence + settle gate — no Vision work.
    ///
    /// Safe to call on the camera delivery queue. The Vision presence check is
    /// deferred to `probeQueue` via `runPresenceCheck(pixelBuffer:)`.
    ///
    /// - Returns: `true` when the cadence interval has elapsed and `isSettled` is `true`.
    func checkCadence(isSettled: Bool) -> Bool {
        let elapsed = clock() - lock.withLock { $0.lastApprovalTime }
        return elapsed >= minInterval && isSettled
    }

    /// Runs the presence gate, records the result, and updates the approval timestamp.
    ///
    /// Call from `probeQueue` only — the Vision request is synchronous.
    /// Updates `lastApprovalTime` regardless of presence so the 5 fps cap applies
    /// to all presence checks (not just positive detections).
    ///
    /// - Returns: `true` if a person is present in the frame.
    func runPresenceCheck(pixelBuffer: CVPixelBuffer) -> Bool {
        let now = clock()
        let result = presenceChecker(pixelBuffer)
        lock.withLock { state in
            state.lastPresenceResult = result   // always record (C1 principle)
            state.lastApprovalTime = now        // caps presence checks at maxFPS
        }
        return result.personPresent
    }

    /// The presence result from the most recent presence check.
    ///
    /// Downstream M2-3/4/5 signal processors use `dominantRect` to scope
    /// body/hand/face geometry to the subject area.
    ///
    /// Lock-protected; safe to call from any thread.
    public var lastPresenceResult: PresenceResult {
        lock.withLock { $0.lastPresenceResult }
    }
}
