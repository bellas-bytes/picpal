import Foundation

// MARK: - VLMSettings

/// Persists the on-device-only toggle across launches using `UserDefaults`.
///
/// When `isOnDeviceOnly` is `true`, the `VLMOrchestrator` short-circuits
/// **before** `FrameEncoder` runs — no JPEG is created, no request is sent.
///
/// ## Thread safety
/// `UserDefaults` reads and writes are thread-safe.
/// `VLMSettings` is `@unchecked Sendable` because it holds no mutable
/// reference-counted state of its own.
public final class VLMSettings: @unchecked Sendable {

    // MARK: - Singleton

    /// Shared instance. Use this in production code.
    public static let shared = VLMSettings()

    // MARK: - Storage key

    private static let onDeviceOnlyKey = "com.picpal.vlm.onDeviceOnly"

    // MARK: - Toggle

    /// `true` when the user has opted out of cloud VLM (Tier 2).
    ///
    /// Setting this to `true` prevents any frame from being encoded or
    /// transmitted for the lifetime of the app. Setting it to `false`
    /// re-enables cloud coaching on the next eligible frame.
    ///
    /// Persisted across launches via `UserDefaults.standard`.
    /// Defaults to `false` (cloud coaching enabled) when never set.
    public var isOnDeviceOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onDeviceOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onDeviceOnlyKey) }
    }

    // MARK: - Init

    private init() {}
}
