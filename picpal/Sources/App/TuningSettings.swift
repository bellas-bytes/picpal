#if DEBUG
import Foundation

/// UserDefaults-backed runtime tuning knobs. DEBUG builds only.
/// Changing these values and relaunching applies the new configuration.
final class TuningSettings: @unchecked Sendable {
    static let shared = TuningSettings()
    private init() {}

    private enum Keys {
        static let cueCooldown       = "com.picpal.tuning.cueCooldown"
        static let minRepeatInterval = "com.picpal.tuning.minRepeatInterval"
        static let vlmCadence        = "com.picpal.tuning.vlmCadence"
        static let aestheticExpiry   = "com.picpal.tuning.aestheticExpiry"
    }

    var cueCooldownSeconds: Double {
        get { stored(Keys.cueCooldown, default: CueEngine.defaultCueCooldownSeconds) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.cueCooldown) }
    }
    var minRepeatIntervalSeconds: Double {
        get { stored(Keys.minRepeatInterval, default: CueEngine.defaultMinRepeatIntervalSeconds) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.minRepeatInterval) }
    }
    var vlmCadenceSeconds: Double {
        get { stored(Keys.vlmCadence, default: VLMRequestGate.defaultCadenceSeconds) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.vlmCadence) }
    }
    var aestheticExpirySeconds: Double {
        get { stored(Keys.aestheticExpiry, default: CueEngine.defaultMinRepeatIntervalSeconds + 1.0) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.aestheticExpiry) }
    }

    func resetToDefaults() {
        [Keys.cueCooldown, Keys.minRepeatInterval, Keys.vlmCadence, Keys.aestheticExpiry]
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    private func stored(_ key: String, default fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }
}
#endif
