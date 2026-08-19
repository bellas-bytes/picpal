/// A coaching instruction selected by the cue engine for one analysis tick.
///
/// `Cue` is a value type — immutable once created. The cue engine produces a new
/// value each tick and never mutates an existing one.
public struct Cue: Sendable, Equatable {

    /// Human-readable instruction text (e.g., "Tilt left a little").
    public let text: String

    /// Priority level — lower rawValue = higher priority.
    public let priority: CuePriority

    /// Which analysis tier produced this cue.
    public let sourceTier: CueSourceTier
}

// MARK: - CuePriority

/// Priority levels used to rank competing cues.
///
/// Lower `rawValue` wins when multiple cues are candidates in the same tick.
/// Gaps in the range are intentional — M2 (body/obstruction) and M3 (VLM/aesthetic)
/// fill in `.body` and `.aesthetic` without touching existing cases.
public enum CuePriority: Int, Sendable, Comparable, CaseIterable {
    case obstruction = -1  // lens obstruction — outranks all cues including stability
    case stability   = 0   // tilt + blur — M1
    case exposure    = 1   // M1
    case composition = 2   // framing — M1
    case body        = 3   // pose — reserved for M2
    case aesthetic   = 4   // VLM — reserved for M3

    public static func < (lhs: CuePriority, rhs: CuePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - CueSourceTier

/// Identifies which analysis tier produced a cue.
public enum CueSourceTier: String, Sendable, Equatable, Encodable {
    case tier0   // on-device CV (M1)
    case tier05  // Vision landmarks (M2)
    case tier2   // cloud VLM (M3)
}
