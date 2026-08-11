import Foundation

// MARK: - ConsentGate

/// Tracks whether the user has consented to the current privacy policy version.
///
/// Consent is versioned so that a privacy policy update can re-prompt the user.
/// Uses the same `UserDefaults.standard` pattern as `VLMSettings`.
public enum ConsentGate {

    // MARK: - Keys

    private enum Keys {
        static let consentVersion = "com.picpal.consent.version"
    }

    // MARK: - Version

    /// The version of the consent this build requires.
    ///
    /// Increment this when the privacy policy changes to re-prompt users who
    /// previously consented to an older version.
    public static let currentConsentVersion: Int = 1

    // MARK: - Query

    /// Returns `true` if the user has consented to the current (or newer) version.
    ///
    /// A stored version that is less than `currentConsentVersion` (including the
    /// default of zero when the key is absent) causes this to return `false`.
    public static func isConsentGiven() -> Bool {
        UserDefaults.standard.integer(forKey: Keys.consentVersion) >= currentConsentVersion
    }

    // MARK: - Record

    /// Records the user's choice and sets `VLMSettings` accordingly.
    ///
    /// Writes `currentConsentVersion` to `UserDefaults` so subsequent launches
    /// skip the consent gate. Then updates `VLMSettings.shared.isOnDeviceOnly`
    /// to reflect the user's cloud-coaching preference.
    ///
    /// - Parameter cloudEnabled: `true` to allow Tier-2 cloud coaching;
    ///   `false` to keep the session on-device only.
    public static func recordConsent(cloudEnabled: Bool) {
        UserDefaults.standard.set(currentConsentVersion, forKey: Keys.consentVersion)
        VLMSettings.shared.isOnDeviceOnly = !cloudEnabled
    }
}
