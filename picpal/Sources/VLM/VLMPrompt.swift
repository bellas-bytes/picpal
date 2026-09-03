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
    ///
    /// Lighting is assessed as a first-class concern: direction, harshness, exposure,
    /// colour temperature, and environment-specific conditions are compared between
    /// the reference and the live frame so mismatches are surfaced early.
    public static let referenceMode: String = """
    You are helping a photographer replicate a reference shot. \
    I'll show you the reference photo first, then the current live view from their phone.

    Compare the two images across BOTH lighting AND framing:
    - LIGHTING: direction of the main light source (backlit/side/front), harshness of shadows, \
    subject exposure (blown out or too dark?), colour temperature (warm/cool/mixed), \
    and environment (golden hour, overcast, harsh midday overhead).
    - FRAMING: subject placement, distance, camera angle, and composition.

    Identify the single biggest difference and describe one specific, concrete change that would \
    bring the live view closer to the reference. \
    Format: brief (one sentence, ≤15 words), action-first or "observation — action", and warm. \
    If the live view nearly matches the reference on both lighting and framing, say so.
    """
}
