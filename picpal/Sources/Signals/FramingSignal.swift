import CoreGraphics

/// Compositional framing assessment for a single camera frame.
public struct FramingSignal: Sendable, Equatable {

    /// Normalized bounding box of the primary subject (Vision coords: origin bottom-left, 0–1).
    /// `nil` when saliency found no clear subject.
    public let subjectBox: CGRect?

    /// The suggested framing adjustment.
    public let hint: FramingHint
}

/// Directional framing hint emitted by the cue engine.
public enum FramingHint: String, Sendable, Equatable, CaseIterable {
    case nudgeLeft
    case nudgeRight
    case nudgeUp
    case nudgeDown
    case tooCentered
    case goodFrame    // subject is well-composed — no adjustment needed
    case noSubject    // saliency found no object — suppress compositional hints
}
