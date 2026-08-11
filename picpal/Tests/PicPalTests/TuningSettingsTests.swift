#if DEBUG
import Testing
@testable import PicPal

// MARK: - TuningSettingsTests

struct TuningSettingsTests {

    // MARK: - resetToDefaults → cue engine default

    @Test("resetToDefaults then read cueCooldownSeconds returns CueEngine default")
    func resetToDefaults_thenRead_returnsCueEngineDefault() {
        TuningSettings.shared.resetToDefaults()
        #expect(TuningSettings.shared.cueCooldownSeconds == CueEngine.defaultCueCooldownSeconds)
    }

    // MARK: - resetToDefaults → VLM default

    @Test("resetToDefaults then read vlmCadenceSeconds returns VLMRequestGate default")
    func resetToDefaults_thenRead_returnsVLMDefault() {
        TuningSettings.shared.resetToDefaults()
        #expect(TuningSettings.shared.vlmCadenceSeconds == VLMRequestGate.defaultCadenceSeconds)
    }

    // MARK: - set cooldown then read back

    @Test("setCooldown then read returns stored value")
    func setCooldown_thenRead_returnsStoredValue() {
        TuningSettings.shared.resetToDefaults()
        TuningSettings.shared.cueCooldownSeconds = 7.5
        #expect(TuningSettings.shared.cueCooldownSeconds == 7.5)
        TuningSettings.shared.resetToDefaults()
    }

    // MARK: - resetToDefaults clears all keys

    @Test("resetToDefaults clears all keys and returns defaults")
    func resetToDefaults_clearsAllKeys() {
        TuningSettings.shared.resetToDefaults()

        // Set all four properties to non-default values.
        TuningSettings.shared.cueCooldownSeconds = 9.0
        TuningSettings.shared.minRepeatIntervalSeconds = 12.0
        TuningSettings.shared.vlmCadenceSeconds = 20.0
        TuningSettings.shared.aestheticExpirySeconds = 15.0

        TuningSettings.shared.resetToDefaults()

        #expect(TuningSettings.shared.cueCooldownSeconds == CueEngine.defaultCueCooldownSeconds)
        #expect(TuningSettings.shared.minRepeatIntervalSeconds == CueEngine.defaultMinRepeatIntervalSeconds)
        #expect(TuningSettings.shared.vlmCadenceSeconds == VLMRequestGate.defaultCadenceSeconds)
        #expect(TuningSettings.shared.aestheticExpirySeconds == CueEngine.defaultMinRepeatIntervalSeconds + 1.0)
    }
}
#endif
