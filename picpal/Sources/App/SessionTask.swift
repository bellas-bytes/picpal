// MARK: - SessionTask

/// A single task in a moderated usability session script.
///
/// Conforms to `Identifiable` so it can be driven by SwiftUI `ForEach` if needed.
/// Conforms to `Sendable` because `SessionTaskScript.m4Tasks` is a `static let` that
/// may be accessed from any isolation context.
struct SessionTask: Sendable, Identifiable {
    let id: Int
    let title: String
    let instructions: String
}

// MARK: - SessionTaskScript

/// Predefined task scripts for moderated usability sessions.
///
/// Tasks are intentionally in production scope (no `#if DEBUG` guard) so that
/// `SessionTask` values can be tested by the unit-test target without the DEBUG
/// flag. The `SessionTaskOverlay` UI that presents them is separately gated.
enum SessionTaskScript {
    static let m4Tasks: [SessionTask] = [
        SessionTask(
            id: 1,
            title: "Photograph a person",
            instructions: "Ask your participant to stand 1–2 m away. Frame them while the app coaches you."
        ),
        SessionTask(
            id: 2,
            title: "Obstruct the lens",
            instructions: "Rest a finger on the lower edge of the lens. Verify the obstruction cue fires within 2s."
        ),
        SessionTask(
            id: 3,
            title: "Check tilt recovery",
            instructions: "Tilt the phone 15° left. Wait for the tilt cue. Return to level. Cue should silence."
        ),
        SessionTask(
            id: 4,
            title: "Check blur recovery",
            instructions: "Shake the phone briefly. Wait for the blur cue. Stabilise. Cue should silence."
        ),
        SessionTask(
            id: 5,
            title: "VLM aesthetic cue",
            instructions: "Hold a stable, novel frame for 10s. Verify a spoken composition remark arrives."
        ),
        SessionTask(
            id: 6,
            title: "VLM offline degradation",
            instructions: "Disable Wi-Fi. Hold a stable frame for 30s. Verify no error cue fires."
        ),
        SessionTask(
            id: 7,
            title: "5-min battery session",
            instructions: "Run the full pipeline for 5 minutes with a person in frame. Note thermal and battery."
        ),
        SessionTask(
            id: 8,
            title: "Non-annoyance check",
            instructions: "Frame a good shot. Observe 60s. Count cues. Target: ~1–3 total (not per subject)."
        ),
    ]
}
