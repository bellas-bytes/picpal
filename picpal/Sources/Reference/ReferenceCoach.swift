import Foundation

/// Maps a PoseDelta to at most one coaching Cue.
/// Stateless — no retained state; the caller (ContentView) holds match confirmation state.
public struct ReferenceCoach {

    /// Named constants for cue text strings.
    public enum CueText {
        public static let moveLeft         = "move them a bit to the left"
        public static let moveRight        = "move them a bit to the right"
        public static let tiltDown         = "tilt down slightly — they're a bit high in the reference"
        public static let tiltUp           = "tilt up slightly — they're a bit low in the reference"
        public static let moreHeadroom     = "leave a bit more space above their head"
        public static let lessHeadroom     = "tighten up — less space above"
        public static let stepCloser       = "step in a bit closer — the reference is tighter"
        public static let stepBack         = "back up slightly — the reference has more space"
        public static let faceCamera       = "have them turn back toward the camera"
        public static let matched          = "nice — that looks like the reference shot"
    }

    /// Cue priority constant for reference coaching.
    /// Matches M2 body-positioning cues.
    private static let referencePriority: CuePriority = .body

    /// Source tier for reference pose-based cues (Vision landmarks).
    private static let referenceSourceTier: CueSourceTier = .tier05

    /// Threshold for face yaw delta in radians.
    /// Must match PoseDelta's private defaultFaceYawThreshold.
    private static let faceYawThreshold: Float = 0.15

    public init() {}

    /// Returns at most one cue for the most significant delta component.
    ///
    /// Logic:
    /// - If `isNewMatch` is true, returns the matched confirmation cue.
    /// - If all delta components are within threshold, returns nil (already matched).
    /// - Otherwise, returns the cue for the highest-priority failing axis component.
    ///
    /// Priority order: face yaw > scale > horizontal > vertical > headroom
    ///
    /// - Parameters:
    ///   - delta: The pose difference between live view and reference.
    ///   - isNewMatch: True when the delta crossed the threshold this frame.
    /// - Returns: A Cue if coaching is needed, or nil if matched or no improvement guidance available.
    public func cue(from delta: PoseDelta, isNewMatch: Bool) -> Cue? {
        // Match confirmation cue takes highest priority: shown when newly matched.
        if isNewMatch {
            return Cue(text: CueText.matched, priority: Self.referencePriority, sourceTier: Self.referenceSourceTier)
        }

        // If all components are within threshold, no coaching needed.
        guard !delta.isWithinThreshold else { return nil }

        // Evaluate each component in priority order and return the first failing one.

        // Priority 1: Face yaw (most visible defect first)
        if let yawDelta = delta.faceYawDelta {
            if abs(yawDelta) >= Self.faceYawThreshold {
                let text = yawDelta > 0 ? CueText.faceCamera : CueText.faceCamera
                return Cue(text: text, priority: Self.referencePriority, sourceTier: Self.referenceSourceTier)
            }
        }

        // Priority 2: Scale (wrong distance is hard to fix without guidance)
        if abs(delta.scaleDelta) >= PoseDelta.defaultScaleMatchThreshold {
            let text = delta.scaleDelta > 0 ? CueText.stepCloser : CueText.stepBack
            return Cue(text: text, priority: Self.referencePriority, sourceTier: Self.referenceSourceTier)
        }

        // Priority 3: Horizontal position
        if abs(delta.horizontalOffset) >= PoseDelta.defaultMatchThreshold {
            let text = delta.horizontalOffset > 0 ? CueText.moveLeft : CueText.moveRight
            return Cue(text: text, priority: Self.referencePriority, sourceTier: Self.referenceSourceTier)
        }

        // Priority 4: Vertical position
        if abs(delta.verticalOffset) >= PoseDelta.defaultMatchThreshold {
            let text = delta.verticalOffset > 0 ? CueText.tiltDown : CueText.tiltUp
            return Cue(text: text, priority: Self.referencePriority, sourceTier: Self.referenceSourceTier)
        }

        // Priority 5: Headroom
        if abs(delta.headroomDelta) >= PoseDelta.defaultMatchThreshold {
            let text = delta.headroomDelta > 0 ? CueText.moreHeadroom : CueText.lessHeadroom
            return Cue(text: text, priority: Self.referencePriority, sourceTier: Self.referenceSourceTier)
        }

        // All components are within threshold; this should not happen because we already checked
        // isWithinThreshold above, but return nil as a safety net.
        return nil
    }
}
