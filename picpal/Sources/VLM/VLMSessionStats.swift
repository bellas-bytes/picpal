import Foundation

// MARK: - VLMSessionStats

/// Lightweight per-session counter for VLM cache telemetry.
/// Guarded externally by `OSAllocatedUnfairLock<VLMSessionStats>` inside `VLMOrchestrator`.
struct VLMSessionStats {
    var cacheHits: Int = 0
    var cacheMisses: Int = 0

    mutating func recordCacheHit()  { cacheHits  += 1 }
    mutating func recordCacheMiss() { cacheMisses += 1 }
}

// MARK: - VLMOrchestratorConstants

/// Shared constants for `VLMOrchestrator`. Internal so extensions in other files can read them.
enum VLMOrchestratorConstants {
    static let queueLabel             = "com.picpal.vlm.orchestrator"
    /// Hard upper-bound on a single VLM round-trip. Timed-out requests never produce a cue.
    static let requestTimeoutSeconds: TimeInterval = 10.0
}

// MARK: - VLMFailureState

/// Offline-degradation failure tracking for `VLMOrchestrator`.
///
/// `consecutiveFailures` resets on every successful VLM round-trip.
/// Once `isDisabledForSession` is `true` it is permanent for the session.
struct VLMFailureState {
    var consecutiveFailures: Int = 0
    var isDisabledForSession: Bool = false
    /// Absolute deadline before which new Tier-2 requests are suppressed.
    /// Initialised to `Date.distantPast` so the first request is never blocked.
    var backoffDeadline: Date = Date.distantPast
}
