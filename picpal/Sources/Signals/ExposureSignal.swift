/// Exposure classification for a single camera frame.
public struct ExposureSignal: Sendable, Equatable {

    /// Fraction of pixels at or below the shadow-clip threshold (0.0–1.0).
    public let shadowClipFraction: Double

    /// Fraction of pixels at or above the highlight-clip threshold (0.0–1.0).
    public let highlightClipFraction: Double

    /// Coarse exposure classification derived from clip fractions.
    public let level: ExposureLevel
}

// MARK: - ExposureLevel

/// Coarse exposure classification emitted per frame.
public enum ExposureLevel: String, Sendable, Equatable {
    case underexposed
    case ok
    case overexposed
}
