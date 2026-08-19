// MARK: - AestheticHint

/// Classification of a VLM aesthetic coaching observation.
///
/// Mirrors the shape of `BodyHint` (M2). The `.nothingToSay` case is both the
/// sentinel for "model found nothing useful" and the parser's safe fallback for
/// any response it cannot classify with confidence.
public enum AestheticHint: String, Sendable, Equatable {
    /// Model said nothing useful, OR the parser rejected the response.
    /// Silence is the safe output — when in doubt, use this.
    case nothingToSay

    /// A valid, actionable, short coaching remark was parsed successfully.
    case remark
}

// MARK: - AestheticSignal

/// Immutable snapshot of one VLM aesthetic-coaching response.
///
/// Mirrors the shape of `BodySignal` (M2). Written by `AestheticResponseParser`
/// and consumed downstream by `VLMOrchestrator` (M3-5).
/// All fields are value types; no lock needed.
public struct AestheticSignal: Sendable, Equatable {

    // MARK: - Properties

    /// Human-readable coaching remark. Empty string when `hint == .nothingToSay`.
    public let remark: String

    /// Parser confidence in the range 0.0–1.0.
    /// `1.0` for a successfully parsed remark; `0.0` for `.nothingToSay`.
    public let confidence: Float

    /// Classification of this signal.
    public let hint: AestheticHint

    // MARK: - Init

    public init(remark: String, confidence: Float, hint: AestheticHint) {
        self.remark = remark
        self.confidence = confidence
        self.hint = hint
    }

    // MARK: - Sentinel

    /// Sentinel returned whenever the model has no useful feedback or the parser
    /// rejects the response. Callers should treat this as "stay quiet".
    public static let nothingToSay = AestheticSignal(
        remark: "",
        confidence: 0.0,
        hint: .nothingToSay
    )
}
