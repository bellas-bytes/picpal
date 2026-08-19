import Foundation

/// Stores and retrieves the post-session survey response.
///
/// Only one response is kept (the most recent session's). Response is a 1–5 Likert scale:
/// 1 = Never, 2 = Rarely, 3 = Sometimes, 4 = Often, 5 = Always.
public enum PostSessionSurvey {

    private enum Keys {
        static let lastResponse = "com.picpal.survey.lastResponse"
    }

    /// Minimum cues emitted in a session before the survey is shown.
    public static let sessionCueThreshold: Int = 3

    /// Valid Likert scale range.
    public static let minResponse: Int = 1
    public static let maxResponse: Int = 5

    /// Stores the response for the most recent session (overwrites any prior).
    public static func record(response: Int) {
        guard response >= minResponse, response <= maxResponse else { return }
        UserDefaults.standard.set(response, forKey: Keys.lastResponse)
    }

    /// Returns the last recorded response, or nil if none has been recorded.
    public static func lastResponse() -> Int? {
        let v = UserDefaults.standard.integer(forKey: Keys.lastResponse)
        return v >= minResponse ? v : nil
    }

    /// Clears the stored response (used for testing isolation).
    static func reset() {
        UserDefaults.standard.removeObject(forKey: Keys.lastResponse)
    }
}
