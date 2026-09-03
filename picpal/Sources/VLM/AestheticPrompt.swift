// MARK: - AestheticPrompt

/// Versioned prompts sent to the VLM for aesthetic coaching.
///
/// The prompt text is the contract between PicPal and the model. It is documented
/// verbatim in source so that any change is visible in code review. The parser in
/// `AestheticResponseParser` is written against the output contract established here.
///
/// **Output contract (v1)**
/// The model must respond with EITHER:
///   (a) One short, action-first coaching remark — ≤ `maxRemarkWords` words,
///       imperative, specific, no hedging, no trailing explanation.
///   (b) The exact token `NOTHING_TO_SAY` when the composition is already good
///       or the model is unsure.
/// Nothing else is acceptable; the parser rejects any other form.
public enum AestheticPrompt {

    // MARK: - Named constants

    /// Maximum number of words a valid remark may contain.
    /// Remarks exceeding this limit are rejected, not truncated — a half-sentence
    /// coach is worse than a quiet one.
    static let maxRemarkWords: Int = 15

    // MARK: - Prompts

    /// Version 1 prompt — verbatim text forwarded to the model.
    ///
    /// Instructs the model to return EITHER:
    ///   (a) One short action-first coaching remark (≤ 15 words, imperative, specific).
    ///   (b) The exact token `NOTHING_TO_SAY` if there is no useful feedback.
    /// Nothing else.
    ///
    /// Lighting is assessed as a first-class concern alongside composition.
    /// The model evaluates direction (backlit/side/front), harshness (hard/soft shadows),
    /// subject exposure (correctly exposed vs blown out or too dark), colour temperature
    /// (casts from fluorescent, tungsten, mixed sources), and environment-specific
    /// conditions (golden hour, midday overhead sun, overcast diffuse).
    public static let v1: String = """
    You are a real-time photo coach. \
    Look at this camera frame and give ONE piece of actionable feedback on either composition OR lighting — whichever needs attention most.

    LIGHTING to assess (check these first — lighting problems are invisible until it's too late):
    - Direction: is the main light behind the subject (backlit)? Side-lit? Front-lit?
    - Harshness: hard shadows from direct sun or harsh artificial light vs soft/diffuse?
    - Subject exposure: face or main subject — correctly exposed, blown out, or too dark?
    - Colour cast: obvious green (fluorescent), warm orange (tungsten), or mixed sources?
    - Environment: golden hour warmth (flattering — say so), overcast (naturally soft — say so), \
    midday overhead sun (warn: harsh shadows under eyes/nose).

    COMPOSITION to assess (if lighting is fine):
    - Framing, subject placement, rule of thirds, horizon level, leading lines.

    Your response must be EITHER:
    - A single short sentence (≤15 words). \
    For lighting feedback the format may be "observation — action" (e.g. "backlit — turn them to face the light"). \
    For positive lighting say so briefly (e.g. "great soft light — keep this"). \
    For composition feedback start with an action verb (e.g. "Move", "Tilt", "Step").
    - The exact token: NOTHING_TO_SAY — if both composition and lighting are already good.
    Do not explain, hedge, or add punctuation beyond the sentence itself. \
    Respond with nothing else.
    """
}
