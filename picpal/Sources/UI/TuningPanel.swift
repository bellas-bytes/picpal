#if DEBUG
import SwiftUI

// MARK: - Stepper range constants

private enum TuningRanges {
    static let cooldownMin: Double = 1.0
    static let cooldownMax: Double = 10.0
    static let cooldownStep: Double = 0.5
    static let repeatMin: Double = 2.0
    static let repeatMax: Double = 15.0
    static let repeatStep: Double = 0.5
    static let cadenceMin: Double = 2.0
    static let cadenceMax: Double = 30.0
    static let cadenceStep: Double = 1.0
    static let expiryMin: Double = 3.0
    static let expiryMax: Double = 20.0
    static let expiryStep: Double = 0.5
}

// MARK: - TuningPanel

/// Debug-only panel for adjusting coaching parameters at runtime without rebuilding.
struct TuningPanel: View {

    @State private var cueCooldown: Double = TuningSettings.shared.cueCooldownSeconds
    @State private var minRepeat: Double = TuningSettings.shared.minRepeatIntervalSeconds
    @State private var vlmCadence: Double = TuningSettings.shared.vlmCadenceSeconds
    @State private var aestheticExpiry: Double = TuningSettings.shared.aestheticExpirySeconds

    var body: some View {
        NavigationStack {
            Form {
                Section("Cue engine") {
                    Stepper(
                        "Cooldown: \(String(format: "%.1f", cueCooldown))s",
                        value: $cueCooldown,
                        in: TuningRanges.cooldownMin...TuningRanges.cooldownMax,
                        step: TuningRanges.cooldownStep
                    )
                    .onChange(of: cueCooldown) { _, newValue in
                        TuningSettings.shared.cueCooldownSeconds = newValue
                    }

                    Stepper(
                        "Repeat interval: \(String(format: "%.1f", minRepeat))s",
                        value: $minRepeat,
                        in: TuningRanges.repeatMin...TuningRanges.repeatMax,
                        step: TuningRanges.repeatStep
                    )
                    .onChange(of: minRepeat) { _, newValue in
                        TuningSettings.shared.minRepeatIntervalSeconds = newValue
                    }
                }

                Section("VLM") {
                    Stepper(
                        "Cadence cap: \(String(format: "%.1f", vlmCadence))s",
                        value: $vlmCadence,
                        in: TuningRanges.cadenceMin...TuningRanges.cadenceMax,
                        step: TuningRanges.cadenceStep
                    )
                    .onChange(of: vlmCadence) { _, newValue in
                        TuningSettings.shared.vlmCadenceSeconds = newValue
                    }

                    Stepper(
                        "Remark expiry: \(String(format: "%.1f", aestheticExpiry))s",
                        value: $aestheticExpiry,
                        in: TuningRanges.expiryMin...TuningRanges.expiryMax,
                        step: TuningRanges.expiryStep
                    )
                    .onChange(of: aestheticExpiry) { _, newValue in
                        TuningSettings.shared.aestheticExpirySeconds = newValue
                    }
                }

                Section {
                    Button("Reset to defaults") {
                        TuningSettings.shared.resetToDefaults()
                        cueCooldown = TuningSettings.shared.cueCooldownSeconds
                        minRepeat = TuningSettings.shared.minRepeatIntervalSeconds
                        vlmCadence = TuningSettings.shared.vlmCadenceSeconds
                        aestheticExpiry = TuningSettings.shared.aestheticExpirySeconds
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Tuning")
        }
    }
}
#endif
