// MARK: - VLMPrivacyDisclosure

/// Privacy disclosure for Tier-2 (cloud VLM) processing.
///
/// Display this text on the same surface as the on-device-only toggle so users
/// can make an informed choice before any image data leaves the device.
///
/// The disclosure is a caseless enum so it cannot be instantiated — it serves
/// purely as a namespace for the static disclosure text.
public enum VLMPrivacyDisclosure {

    /// One-paragraph disclosure suitable for a Settings / Privacy screen.
    ///
    /// Covers: what stays on-device, what is sent for Tier 2, the maximum
    /// resolution cap, what is NOT sent, and how to disable cloud coaching.
    public static let text: String = """
    PicPal's composition coaching uses two layers:

    On-device only (Tier 0/0.5): Tilt, blur, exposure, framing, body pose, \
    hand detection, and gaze — all processed entirely on your device. \
    No image data leaves your iPhone for these features.

    Optional cloud coaching (Tier 2): When enabled, PicPal occasionally \
    sends a downscaled JPEG (max \(FrameEncoder.maxDimension)px on the \
    longest edge) of a stable frame to a secure proxy for aesthetic \
    composition feedback. No audio, location, identity, or account \
    information is included. Images are not stored by the app or the proxy.

    Reference coaching asks separately before sending your selected reference \
    photo with live frames. Its description stays in memory for this session. \
    Without cloud permission, PicPal gives local framing and pose guidance; \
    it cannot confirm an overall reference match or automatically capture one.

    You can disable cloud coaching at any time using the toggle below. \
    When disabled, no image data is ever encoded or transmitted.
    """
}
