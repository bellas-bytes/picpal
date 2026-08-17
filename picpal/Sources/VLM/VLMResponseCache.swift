import Foundation
import os.log

/// In-session VLM response cache. On-device only; never persisted.
/// Keyed by SceneSignature similarity (not exact match).
final class VLMResponseCache: @unchecked Sendable {

    static let defaultMaxEntries: Int = 20
    static let defaultTTLSeconds: Double = 30.0

    struct Entry: Sendable {
        let signature: SceneSignature
        let signal: AestheticSignal
        let timestamp: Date
    }

    private let lock: OSAllocatedUnfairLock<[Entry]>
    private let maxEntries: Int
    private let ttlSeconds: Double
    private let clock: @Sendable () -> Date

    init(
        maxEntries: Int = defaultMaxEntries,
        ttlSeconds: Double = defaultTTLSeconds,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.lock = OSAllocatedUnfairLock(initialState: [])
        self.maxEntries = maxEntries
        self.ttlSeconds = ttlSeconds
        self.clock = clock
    }

    /// Returns a cached AestheticSignal if a non-materially-different,
    /// non-expired entry exists; nil otherwise.
    func lookup(for signature: SceneSignature) -> AestheticSignal? {
        let now = clock()
        return lock.withLock { entries in
            entries.first(where: { entry in
                !entry.signature.isMateriallyDifferent(from: signature) &&
                now.timeIntervalSince(entry.timestamp) < ttlSeconds
            })?.signal
        }
    }

    /// Stores a response for a given signature.
    /// Moves existing same-signature entries to front (LRU refresh).
    /// Drops the tail entry when at capacity.
    func store(_ signal: AestheticSignal, for signature: SceneSignature) {
        let entry = Entry(signature: signature, signal: signal, timestamp: clock())
        lock.withLock { entries in
            entries.removeAll { !$0.signature.isMateriallyDifferent(from: signature) }
            entries.insert(entry, at: 0)
            if entries.count > maxEntries {
                entries.removeLast()
            }
        }
    }

    /// Clears all entries. Call on app background / session end.
    func invalidate() {
        lock.withLock { $0.removeAll() }
    }

    /// Current entry count. For telemetry / testing.
    var count: Int {
        lock.withLock { $0.count }
    }
}
