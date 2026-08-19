import Foundation

/// Immutable snapshot of all computed signals for one analyzed frame.
///
/// All signal fields are optional: `nil` means the corresponding signal has not
/// yet been computed for this frame (either because the module is not yet active
/// or because this frame was skipped for that analysis path).
///
/// ## Extensibility
/// Future milestones add new signal types by adding a new optional field here
/// and a new file in `Signals/`. Existing callers that don't use the new field
/// are unaffected --- the memberwise init gains a defaulted parameter.
public struct SignalFrame: Sendable {

    // MARK: - Common

    /// Timestamp from the originating `MotionReading` or `CMTime`.
    public let timestamp: TimeInterval

    // MARK: - Tier 0 signals

    /// Device tilt angle and level state. `nil` until M1-1 is active.
    public let tilt: TiltSignal?

    /// Blur / sharpness score. `nil` until M1-2 is active.
    public let blur: BlurSignal?

    /// Exposure level classification. `nil` until M1-3 is active.
    public let exposure: ExposureSignal?

    /// Subject framing assessment. `nil` until M1-4 is active.
    public let framing: FramingSignal?

    // MARK: - Tier 2 signals

    /// Body-framing signal produced by M2-3/4/5. `nil` until M2-3 is active.
    public let body: BodySignal?

    // MARK: - Tier 3 signals

    /// Aesthetic coaching signal produced by M3-5 VLM tier. `nil` until M3-5 is active.
    public let aesthetic: AestheticSignal?

    // MARK: - Tier 6 signals

    /// Group framing geometry. Non-nil when >=2 persons are detected in frame.
    public let groupPresence: GroupPresence?

    // MARK: - Memberwise initialiser

    /// Full memberwise initialiser --- new optional fields default to `nil`.
    public init(
        timestamp: TimeInterval,
        tilt: TiltSignal? = nil,
        blur: BlurSignal? = nil,
        exposure: ExposureSignal? = nil,
        framing: FramingSignal? = nil,
        body: BodySignal? = nil,
        aesthetic: AestheticSignal? = nil,
        groupPresence: GroupPresence? = nil
    ) {
        self.timestamp = timestamp
        self.tilt = tilt
        self.blur = blur
        self.exposure = exposure
        self.framing = framing
        self.body = body
        self.aesthetic = aesthetic
        self.groupPresence = groupPresence
    }

    // MARK: - Convenience

    /// A `SignalFrame` with all signals set to `nil` and timestamp `0`.
    ///
    /// Useful as a starting value in tests and as the initial state in view-models.
    public static let empty = SignalFrame(timestamp: 0)
}
