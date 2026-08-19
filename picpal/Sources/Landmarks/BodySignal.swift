import CoreGraphics

// MARK: - BodyHint

/// Classification of a body-framing observation.
///
/// Cases are ordered from highest to lowest priority in the cue engine (M2-6).
public enum BodyHint: Sendable, Equatable {
    /// A hand or finger is over the lens — highest priority.
    case lensObstructed
    /// A limb or the head is intersecting the frame at an awkward crop joint.
    case awkwardCrop
    /// The subject's face is turned away from the camera.
    case gazeAway
    /// The subject needs more headroom — nudge the frame up.
    case nudgeUpHeadroom
    /// The subject has too much headroom — nudge the frame down.
    case nudgeDownHeadroom
    /// All body signals are clear — no correction needed.
    case goodBody
}

// MARK: - BodySignal

/// Immutable snapshot of one body-framing analysis pass.
///
/// Written by M2-3/4/5 signal processors and consumed by the M2-6 cue engine.
/// All fields are value types; no lock is needed.
public struct BodySignal: Sendable, Equatable {

    // MARK: - Properties

    /// Primary body-framing hint for this frame.
    public let hint: BodyHint

    /// Aggregate detection confidence in the range 0.0–1.0.
    public let confidence: Float

    /// Subject bounding rect in UIKit-normalized coordinates (top-left origin, 0–1).
    /// `nil` when no subject rect is available (e.g. `noPersonPresent`).
    public let dominantRect: CGRect?

    // MARK: - Init

    public init(hint: BodyHint, confidence: Float, dominantRect: CGRect?) {
        self.hint = hint
        self.confidence = confidence
        self.dominantRect = dominantRect
    }

    // MARK: - Sentinels

    /// Sentinel used by M2-6 for the no-person fallback path.
    ///
    /// `hint` is `.goodBody` (no bad cues), `confidence` is zero (no person),
    /// and `dominantRect` is `nil`.
    public static let noPersonPresent = BodySignal(
        hint: .goodBody,
        confidence: 0,
        dominantRect: nil
    )
}
