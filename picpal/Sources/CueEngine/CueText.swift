/// Maps signal states to spoken cue text.
///
/// All strings are action-first and brief — the speaker delivers them in
/// the middle of composing a photo and has limited attention.
///
/// These are intentionally plain constants (not a keyed enum) so the cue engine
/// can compare text strings for repeat-suppression without carrying the enum
/// case through the debounce state.
public enum CueText {

    // MARK: - Tilt

    /// Coaching cue when the device is tilted clockwise (positive angle).
    ///
    /// Positive `angleDegrees` means the right side of the device is lower;
    /// tilting left corrects it.
    public static let tiltLeft    = "Tilt left a little"

    /// Coaching cue when the device is tilted counter-clockwise (negative angle).
    public static let tiltRight   = "Tilt right a little"

    // MARK: - Blur

    /// Coaching cue when the frame is classified as blurry.
    public static let holdStill   = "Hold still"

    // MARK: - Exposure

    /// Coaching cue when the frame is overexposed.
    public static let tooLight    = "Too much light — step back or angle away"

    /// Coaching cue when the frame is underexposed.
    public static let tooDark     = "Too dark — find more light"

    // MARK: - Framing / Composition

    /// Coaching cue when the subject should move left in the frame.
    public static let nudgeLeft   = "Nudge left"

    /// Coaching cue when the subject should move right in the frame.
    public static let nudgeRight  = "Nudge right"

    /// Coaching cue when the subject should move upward in the frame.
    public static let nudgeUp     = "Move up a little"

    /// Coaching cue when the subject should move downward in the frame.
    public static let nudgeDown   = "Move down a little"

    /// Coaching cue when the subject is centred and off-centre composition is preferred.
    public static let tooCentered = "Off-center a little for a nicer composition"

    // MARK: - Body / Obstruction (M2)

    /// Lens obstruction — finger cluster over the camera.
    public static let lensObstructed    = "Move your hand away from the lens"

    /// Awkward crop — a limb or joint is at the frame edge.
    public static let awkwardCrop       = "Adjust your framing — something's getting cut off"

    /// Gaze away — subject's face is turned from camera.
    public static let gazeAway          = "Look toward the camera"

    /// Headroom — subject is too close to the top of the frame.
    public static let nudgeDownHeadroom = "Move the camera down a little"

    /// Headroom — subject has too much space above their head.
    public static let nudgeUpHeadroom   = "Move the camera up a little"

    // MARK: - Good frame

    /// Displayed in the debug overlay when no coaching adjustment is needed.
    ///
    /// The cue engine emits `nil` (silence) instead of this cue — the engine's
    /// contract is "one cue or nothing". This string is available for UI labels
    /// (e.g., the debug overlay) that want to show a positive state.
    public static let goodFrame   = "Looking good"

    // MARK: - Predictive coaching (M6)

    // Predictive hints — emitted while a signal is actively improving toward threshold.
    public static let tiltAlmostLevel   = "almost level"
    public static let exposureImproving = "light's getting better, hold a moment"

    // Positive confirmations — emitted when the signal crosses the threshold mid-session.
    public static let tiltConfirmed     = "that's it"
    public static let exposureConfirmed = "nice light"

    // MARK: - Group coaching (M6)

    public static let groupCutOffLeft  = "someone's getting cut off on the left"
    public static let groupCutOffRight = "someone's getting cut off on the right"
    public static let groupSpreadWide  = "group is spread too wide, move back"
    public static let groupLearnIn     = "lean in, you're too far apart"
    public static let groupTooHigh     = "group is too high, tilt camera down"
}
