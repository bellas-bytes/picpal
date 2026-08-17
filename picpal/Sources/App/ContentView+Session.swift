import SwiftUI

// MARK: - AestheticExpiryHandle

/// Holds a cancellable expiry Task so `@Sendable` closures in `wireUp()` can share
/// the mutable task handle without capturing the view struct.
///
/// Declared as a `final class` (reference type) so the `@Sendable` closures that capture
/// it by value still share the same underlying storage. All mutations are dispatched on
/// `@MainActor` via `Task { @MainActor in … }` blocks.
final class AestheticExpiryHandle: @unchecked Sendable {
    /// The pending expiry task, if any.  Always read and written on `@MainActor`.
    nonisolated(unsafe) var task: Task<Void, Never>? = nil
}

// MARK: - Private constants

/// Auto-expiry window for an aesthetic remark: one second past the cue-engine repeat interval
/// so the accumulator silences naturally before the coach would re-fire the same coaching line.
private let aestheticRemarkExpirySeconds = CueEngine.defaultMinRepeatIntervalSeconds + 1.0

// MARK: - ContentView+Session

extension ContentView {

    // MARK: - Scene phase handler

    /// Responds to scene-phase transitions.
    ///
    /// - On `.background`: resets the settle timer to prevent stale latency outliers
    ///   from a prior foreground session corrupting KPI percentiles, then exports a
    ///   telemetry snapshot, and schedules the post-session survey if eligible.
    /// - On `.active`: restarts the battery session tracker.
    func handleScenePhaseChange(to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            settleEventTimer?.reset()   // prevent stale timestamp from prior foreground session
            vlmOrchestrator?.invalidateCache()
            exportSnapshot(surveyResponse: nil)
            // Set flag so survey appears on next foreground; shown at most once per lifecycle.
            if !surveyShownThisSession &&
               (cueLogger?.events().count ?? 0) >= PostSessionSurvey.sessionCueThreshold {
                showSurvey = true
                surveyShownThisSession = true
            }
        case .active:
            batteryMonitor.startSession()
        default:
            break
        }
    }

    // MARK: - Telemetry export

    /// Builds a `TelemetrySnapshot` from current session state and writes it to disk.
    ///
    /// `TelemetryFeed` does not expose `currentStats` or `thermalEvents` as public
    /// properties — placeholders (`FrameTimerStatistics.empty` and `[]`) are used
    /// until those are surfaced. See task-m4-2-report.md for the follow-up note.
    @MainActor
    func exportSnapshot(surveyResponse: Int?) {
        let report = cueLogger?.makeSummary()
        let batteryReport = batteryMonitor.endSession()
        let stats = vlmOrchestrator?.sessionStats
        let snapshot = TelemetrySnapshot(
            frameStats: FrameTimerStatistics.empty,
            thermalEvents: [],
            batteryReport: batteryReport,
            cueTelemetry: report,
            surveyResponse: surveyResponse,
            vlmCacheHits: stats?.cacheHits,
            vlmCacheMisses: stats?.cacheMisses
        )
        try? telemetryExporter?.export(snapshot: snapshot)
        batteryMonitor.startSession()   // restart immediately for next foreground session
    }

    // MARK: - Composition root

    @MainActor
    func wireUp() {
        guard telemetryFeed == nil else { return }  // idempotent

        // Create the cue engine and signal accumulator.
        // The accumulator merges individual signals into a complete SignalFrame and
        // passes it to the engine on every update. Results are dispatched to @MainActor.
        #if DEBUG
        let engine = CueEngine(
            cueCooldownSeconds: TuningSettings.shared.cueCooldownSeconds,
            minRepeatIntervalSeconds: TuningSettings.shared.minRepeatIntervalSeconds
        )
        #else
        let engine = CueEngine()
        #endif
        let coach = voiceCoach  // capture strong local reference (no retain cycle)
        // Capture the class reference so @Sendable closures below can cancel/reschedule
        // the expiry Task through the shared handle without capturing the view struct.
        let expiryHandle = aestheticExpiryTask
        let logger = CueLogger()
        let settleTimer = SettleEventTimer()
        let accum = SignalFrameAccumulator { [weak debugViewModel] frame in
            let cue = engine.process(frame: frame)
            if let cue {
                let now = Date()
                let latencyMs = settleTimer.latencyMilliseconds(cueAt: now)
                let event = CueEvent(
                    timestamp: now,
                    text: cue.text,
                    tier: cue.sourceTier,
                    latencyFromSettleMs: latencyMs
                )
                logger.record(event)
                settleTimer.reset()   // reset after first cue; next settle starts a new burst
                coach.speak(cue)
            }
            let cueText = cue?.text ?? "—"
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.activeCue = cueText
            }
        }

        let framingMon = FramingMonitor { [weak debugViewModel, accum] signal in
            accum.update(framing: signal)
            let label = signal.hint.rawValue
            let box = signal.subjectBox
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.framingHint = label
                debugViewModel?.subjectBox = box
            }
        }

        let exposureMon = ExposureMonitor(downstream: framingMon) { [weak debugViewModel, accum] signal in
            accum.update(exposure: signal)
            let label: String
            switch signal.level {
            case .ok:           label = "ok"
            case .underexposed: label = "under"
            case .overexposed:  label = "over"
            }
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.exposureLevel = label
            }
        }

        let blurMon = BlurMonitor(downstream: exposureMon) { [weak debugViewModel, accum] signal in
            accum.update(blur: signal)
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.blurScore = signal.sharpnessScore
            }
        }

        // Landmark probe is disabled by default — body/hand/face Vision runs every frame
        // and wastes thermal budget when nothing yet consumes landmark results (M2+).
        let probe = VisionLandmarkProbe(isEnabled: false, downstream: blurMon) { [weak debugViewModel] stats in
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.bodyPoseMs         = stats.bodyPoseMs
                debugViewModel?.handPoseMs         = stats.handPoseMs
                debugViewModel?.faceMeshMs         = stats.faceMeshMs
                debugViewModel?.landmarkCombinedMs = stats.combinedMs
            }
        }

        // Tier-2: VLMOrchestrator sits between LandmarkOrchestrator and the telemetry bridge.
        // Created before LandmarkOrchestrator so vlmOrch can be captured in the body-signal
        // callback to keep StaleSuppressor's body-hint arm updated.
        #if DEBUG
        let vlmGate = VLMRequestGate(cadenceSeconds: TuningSettings.shared.vlmCadenceSeconds)
        #else
        let vlmGate = VLMRequestGate()
        #endif
        let vlmOrch = VLMOrchestrator(
            client: AnthropicVLMClient(proxyURL: VLMSettings.shared.proxyURL),
            gate: vlmGate,
            onRequestDispatched: { [weak debugViewModel, expiryHandle] in
                // Cancel any pending expiry: the incoming response will set a fresh one.
                Task { @MainActor [weak debugViewModel, expiryHandle] in
                    expiryHandle.task?.cancel()
                    expiryHandle.task = nil
                    debugViewModel?.isVLMInFlight = true
                }
            },
            onRequestCompleted: { [weak debugViewModel] in
                Task { @MainActor [weak debugViewModel] in
                    debugViewModel?.isVLMInFlight = false
                }
            },
            onResponseDiscarded: { [weak debugViewModel] in
                Task { @MainActor [weak debugViewModel] in
                    debugViewModel?.vlmDiscardCount += 1
                }
            },
            onAestheticSignal: { [weak debugViewModel, accum, expiryHandle] signal in
                accum.update(aesthetic: signal)
                switch signal.hint {
                case .remark:
                    // Cancel any previous expiry Task and schedule a fresh one.
                    Task { @MainActor [weak debugViewModel, accum, expiryHandle] in
                        expiryHandle.task?.cancel()
                        expiryHandle.task = nil
                        debugViewModel?.aestheticRemark = signal.remark
                        let newTask = Task { [accum, weak debugViewModel] in
                            try? await Task.sleep(for: .seconds(aestheticRemarkExpirySeconds))
                            guard !Task.isCancelled else { return }
                            accum.update(aesthetic: AestheticSignal.nothingToSay)
                            await MainActor.run { [weak debugViewModel] in
                                debugViewModel?.aestheticRemark = ""
                            }
                        }
                        expiryHandle.task = newTask
                    }
                case .nothingToSay:
                    // VLM returned nothing — cancel any pending expiry (no remark to expire).
                    Task { @MainActor [weak debugViewModel, expiryHandle] in
                        expiryHandle.task?.cancel()
                        expiryHandle.task = nil
                        debugViewModel?.aestheticRemark = ""
                    }
                }
            }
        )

        // Create the landmark orchestrator. If model files are absent (e.g. Simulator),
        // try? returns nil and the pipeline degrades gracefully to the existing path.
        let orchestrator = try? LandmarkOrchestrator { [weak debugViewModel, accum, vlmOrch] signal in
            accum.update(body: signal)
            vlmOrch.update(bodyHint: signal.hint)
            let label = signal.hint == .goodBody ? "" : String(describing: signal.hint)
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.bodyHint = label
            }
        }

        let feed = debugViewModel.makeTelemetryFeed(downstream: probe)
        vlmOrch.downstream = feed.bridge

        // Wire: LandmarkOrchestrator → VLMOrchestrator → telemetry bridge.
        // When orchestrator is nil (Simulator — model files absent), vlmOrch becomes
        // the direct adapter downstream so Tier-2 wiring stays intact.
        orchestrator?.downstream = vlmOrch
        let adapterDownstream: any CameraFrameDelegate = orchestrator ?? vlmOrch
        let adapter = SceneGateAdapter(gate: sceneGate, downstream: adapterDownstream)
        camera.delegate = adapter
        feed.start()
        camera.requestPermissionAndStart()

        blurMonitor = blurMon
        exposureMonitor = exposureMon
        framingMonitor = framingMon
        landmarkProbe = probe
        landmarkOrchestrator = orchestrator
        vlmOrchestrator = vlmOrch
        telemetryFeed = feed
        sceneGateAdapter = adapter
        cueEngine = engine
        accumulator = accum
        cueLogger = logger
        settleEventTimer = settleTimer

        batteryMonitor.startSession()
        telemetryExporter = try? TelemetryExporter.inDocuments()

        #if DEBUG
        // ContentView is a struct — [weak self] is not valid.
        // Capture the class instances (BatteryMonitor, CueLogger) and the struct value
        // (TelemetryExporter?) directly; they're stable after wireUp() completes.
        let battery = batteryMonitor
        let exporterValue = telemetryExporter
        let cueLog = logger
        debugViewModel.onExportTelemetry = {
            Task { @MainActor in
                let report = cueLog.makeSummary()
                let batteryReport = battery.endSession()
                let snapshot = TelemetrySnapshot(
                    frameStats: FrameTimerStatistics.empty,
                    thermalEvents: [],
                    batteryReport: batteryReport,
                    cueTelemetry: report,
                    surveyResponse: nil
                )
                try? exporterValue?.export(snapshot: snapshot)
                battery.startSession()
            }
        }
        #endif

        let monitor = TiltMonitor(onSettleChange: { [sceneGate] settled in
            sceneGate.update(isSettled: settled)
            if settled {
                settleTimer.recordSettle()
            }
        }) { [weak debugViewModel, accum] signal in
            accum.update(tilt: signal)
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.tiltDegrees = signal.angleDegrees
                debugViewModel?.isLevel = signal.isLevel
            }
        }
        motionManager.delegate = monitor
        motionManager.start()
        // On Simulator (and any device where motion is unavailable), MotionManager.start()
        // returns early without ever firing didChangeSettled.  Open the gate immediately so
        // frames reach the analysis pipeline.
        if !motionManager.isDeviceMotionAvailable {
            sceneGate.update(isSettled: true)
        }
        tiltMonitor = monitor
    }
}
