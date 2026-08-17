import Foundation

/// A single recorded cue emission, captured at the moment `CueEngine` returns a non-nil cue.
///
/// `CueEvent` is a lightweight value type. It carries enough information to compute
/// KPIs for actionable latency (settle → first cue) and cue-count distribution by tier.
public struct CueEvent: Sendable, Encodable, Equatable {
    /// Wall-clock time when the cue was emitted.
    public let timestamp: Date

    /// The human-readable coaching instruction text (matches `Cue.text`).
    public let text: String

    /// Which analysis tier produced this cue.
    public let tier: CueSourceTier

    /// Elapsed milliseconds between the most recent settle event and this cue emission.
    /// `nil` when no settle was recorded for the current burst.
    public let latencyFromSettleMs: Double?
}
