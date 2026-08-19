// MARK: - VLMPrompt

/// Named prompt constants for VLM coaching modes.
///
/// Each prompt is the full-text contract sent to the model.  Keeping prompts
/// as named constants means every change is visible in diff / code review and
/// the call-site never contains inline strings.
public enum VLMPrompt {

    // MARK: - Reference mode

    /// Prompt for two-image reference-photo coaching.
    ///
    /// The proxy presents the reference image first, then the live frame.
    /// The model returns one concrete, action-first sentence (or a near-match
    /// acknowledgement) that guides the photographer toward the reference shot.
    public static let referenceMode: String = """
    You are helping a photographer replicate a reference shot. \
    I'll show you the reference photo first, then the current live view from their phone. \
    Describe one specific, concrete change that would bring the live view closer to the reference \
    in terms of framing, subject placement, or lighting. \
    Be brief (one sentence), action-first, and warm. \
    If they've nearly matched it, say so.
    """
}
