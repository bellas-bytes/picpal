import Foundation

// MARK: - VLMSessionStats

/// Lightweight per-session counter for VLM cache telemetry.
/// Guarded externally by `OSAllocatedUnfairLock<VLMSessionStats>` inside `VLMOrchestrator`.
public struct VLMSessionStats: Codable, Sendable {
    public private(set) var cacheHits = 0
    public private(set) var cacheMisses = 0
    public private(set) var networkAttempts = 0
    public private(set) var acceptedResults = 0
    public private(set) var staleDiscards = 0
    public private(set) var requests: [VLMRequestMeasurement] = []

    mutating func recordCacheHit() { cacheHits += 1 }
    mutating func recordCacheMiss() { cacheMisses += 1 }
    mutating func begin(id: UUID, operation: VLMOperation, capturedAt: TimeInterval?, encodingSeconds: TimeInterval, cacheHit: Bool) {
        if requests.count == 128 { requests.removeFirst() }
        requests.append(VLMRequestMeasurement(id: id, operation: operation, capturedAt: capturedAt,
            encodingSeconds: encodingSeconds, cacheHit: cacheHit))
    }
    mutating func dispatched(id: UUID, at time: TimeInterval) {
        networkAttempts += 1
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].attempts += 1
        if requests[index].dispatchedAt == nil { requests[index].dispatchedAt = time }
    }
    mutating func completed(id: UUID, at time: TimeInterval, outcome: VLMRequestMeasurement.Outcome) {
        guard let index = requests.firstIndex(where: { $0.id == id }), requests[index].completedAt == nil else { return }
        requests[index].completedAt = time
        requests[index].outcome = outcome
        if outcome == .accepted { acceptedResults += 1 }
        if outcome == .stale { staleDiscards += 1 }
    }
}

/// Metadata only. Times use the orchestrator's injected Unix-seconds clock.
public struct VLMRequestMeasurement: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case accepted, stale, failed }
    public let id: UUID
    public let operation: VLMOperation
    public let capturedAt: TimeInterval?
    public let encodingSeconds: TimeInterval
    public let cacheHit: Bool
    public fileprivate(set) var dispatchedAt: TimeInterval?
    public fileprivate(set) var completedAt: TimeInterval?
    public fileprivate(set) var attempts = 0
    public fileprivate(set) var outcome: Outcome?
    public var completionLatency: TimeInterval? {
        guard let capturedAt, let completedAt else { return nil }
        return max(0, completedAt - capturedAt)
    }
}

// MARK: - VLMOrchestratorConstants

/// Shared constants for `VLMOrchestrator`. Internal so extensions in other files can read them.
enum VLMOrchestratorConstants {
    static let idleRefreshSeconds: TimeInterval = 20
    static let comparisonFreshnessSeconds: TimeInterval = 8
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
