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
    static let cacheTTLMin: Double = 5.0
    static let cacheTTLMax: Double = 120.0
    static let cacheTTLStep: Double = 5.0
    static let cacheMaxEntriesMin: Double = 5.0
    static let cacheMaxEntriesMax: Double = 100.0
    static let cacheMaxEntriesStep: Double = 5.0
    static let waitWindowMin: Double = 0.5
    static let waitWindowMax: Double = 10.0
    static let waitWindowStep: Double = 0.5
    static let slopeMin: Double = 0.01
    static let slopeMax: Double = 0.20
    static let slopeStep: Double = 0.01
}

// MARK: - TuningPanel

/// Debug-only panel for adjusting coaching parameters at runtime without rebuilding.
struct TuningPanel: View {

    @State private var cueCooldown: Double = TuningSettings.shared.cueCooldownSeconds
    @State private var minRepeat: Double = TuningSettings.shared.minRepeatIntervalSeconds
    @State private var vlmCadence: Double = TuningSettings.shared.vlmCadenceSeconds
    @State private var cacheTTL: Double = TuningSettings.shared.vlmCacheTTLSeconds
    @State private var cacheMaxEntries: Double = Double(TuningSettings.shared.vlmCacheMaxEntries)
    @State private var waitWindow: Double = TuningSettings.shared.predictiveWaitWindowSeconds
    @State private var slopeThreshold: Double = TuningSettings.shared.trendImprovementSlope

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
                        "Cache TTL: \(String(format: "%.0f", cacheTTL))s",
                        value: $cacheTTL,
                        in: TuningRanges.cacheTTLMin...TuningRanges.cacheTTLMax,
                        step: TuningRanges.cacheTTLStep
                    )
                    .onChange(of: cacheTTL) { _, newValue in
                        TuningSettings.shared.vlmCacheTTLSeconds = newValue
                    }

                    Stepper(
                        "Max entries: \(Int(cacheMaxEntries))",
                        value: $cacheMaxEntries,
                        in: TuningRanges.cacheMaxEntriesMin...TuningRanges.cacheMaxEntriesMax,
                        step: TuningRanges.cacheMaxEntriesStep
                    )
                    .onChange(of: cacheMaxEntries) { _, newValue in
                        TuningSettings.shared.vlmCacheMaxEntries = Int(newValue)
                    }
                }

                Section("Predictive coaching") {
                    Stepper(
                        "Wait window: \(String(format: "%.1f", waitWindow))s",
                        value: $waitWindow,
                        in: TuningRanges.waitWindowMin...TuningRanges.waitWindowMax,
                        step: TuningRanges.waitWindowStep
                    )
                    .onChange(of: waitWindow) { _, newValue in
                        TuningSettings.shared.predictiveWaitWindowSeconds = newValue
                    }
                    Stepper(
                        "Improvement slope: \(String(format: "%.3f", slopeThreshold))",
                        value: $slopeThreshold,
                        in: TuningRanges.slopeMin...TuningRanges.slopeMax,
                        step: TuningRanges.slopeStep
                    )
                    .onChange(of: slopeThreshold) { _, newValue in
                        TuningSettings.shared.trendImprovementSlope = newValue
                    }
                }

                Section {
                    Button("Reset to defaults") {
                        TuningSettings.shared.resetToDefaults()
                        cueCooldown = TuningSettings.shared.cueCooldownSeconds
                        minRepeat = TuningSettings.shared.minRepeatIntervalSeconds
                        vlmCadence = TuningSettings.shared.vlmCadenceSeconds
                        cacheTTL = TuningSettings.shared.vlmCacheTTLSeconds
                        cacheMaxEntries = Double(TuningSettings.shared.vlmCacheMaxEntries)
                        waitWindow = TuningSettings.shared.predictiveWaitWindowSeconds
                        slopeThreshold = TuningSettings.shared.trendImprovementSlope
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Tuning")
        }
    }
}
#endif
