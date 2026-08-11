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
    public static let v1: String = """
    You are a real-time photo composition coach. \
    Look at this camera frame and give ONE piece of actionable feedback to improve the composition. \
    Your response must be EITHER:
    - A single short sentence (≤15 words), starting with an action verb (e.g. "Move", "Tilt", "Step"), \
    describing one specific improvement.
    - The exact token: NOTHING_TO_SAY — if the composition is already good or you are unsure.
    Do not explain, hedge, or add punctuation beyond the sentence itself. \
    Respond with nothing else.
    """
}
