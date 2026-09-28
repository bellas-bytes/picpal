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
            predictiveCoordinator.reset()
            vlmOrchestrator?.invalidateCache()
            clearReferenceState()       // reference mode does not persist across background cycles
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

    // MARK: - Composition root

    @MainActor
    func wireUp() {
        guard telemetryFeed == nil else { return }  // idempotent

        // Check proxy health on launch — non-blocking; logs a warning when near ceiling.
        Task {
            let endpoint = VLMSettings.shared.proxyURL.deletingLastPathComponent().appendingPathComponent("health")
            let health = await ProxyHealthClient(healthURL: endpoint).checkHealth()
            if !health.isReachable {
                print("[picpal] Proxy health check: unreachable — is the proxy running?")
            } else if health.isNearCeiling {
                print("[picpal] Proxy health check: near ceiling (\(health.calls)/\(health.ceiling) calls used).")
            } else {
                print("[picpal] Proxy health check: ok (\(health.calls)/\(health.ceiling) calls used).")
            }
        }
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
        let screen = cameraScreen
        // Capture the class reference so @Sendable closures below can cancel/reschedule
        // the expiry Task through the shared handle without capturing the view struct.
        let expiryHandle = aestheticExpiryTask
        let logger = CueLogger()
        let settleTimer = SettleEventTimer()
        let coordinator = predictiveCoordinator
        let accum = SignalFrameAccumulator { [weak debugViewModel] frame in
            let predictive = coordinator.update(frame)
            let cue = engine.process(frame: frame, predictive: predictive)
            if let cue {
                let now = Date()
                let latencyMs = settleTimer.latencyMilliseconds(cueAt: now)
                let event = CueEvent(
                    timestamp: now,
                    text: cue.text,
                    tier: cue.sourceTier,
                    latencyFromSettleMs: latencyMs,
                    predictiveHintIssued: cue.text == CueText.tiltAlmostLevel
                        || cue.text == CueText.exposureImproving
                )
                logger.record(event)
                settleTimer.reset()   // reset after first cue; next settle starts a new burst
                // Primary spoken guidance now follows fresh person observations.
            }
            // Reference matching also uses the fresh person observation in CameraScreenModel.
            Task { @MainActor [weak debugViewModel] in
                debugViewModel?.receiveCoachingCue(cue)
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

        let blurMon = BlurMonitor(downstream: framingMon) { [weak debugViewModel, accum] signal in
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
        #if DEBUG
        let vlmCache = VLMResponseCache(
            maxEntries: TuningSettings.shared.vlmCacheMaxEntries,
            ttlSeconds: TuningSettings.shared.vlmCacheTTLSeconds
        )
        #else
        let vlmCache = VLMResponseCache()
        #endif
        let vlmOrch = VLMOrchestrator(
            client: ConfiguredVLMClient(),
            gate: vlmGate,
            responseCache: vlmCache,
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
            onReferenceAnalysis: { event in
                Task { @MainActor in screen.receive(referenceAnalysis: event) }
            },
            onAestheticSignal: { [weak debugViewModel, accum, expiryHandle] signal in
                accum.update(aesthetic: signal)
                switch signal.hint {
                case .remark:
                    // Cancel any previous expiry Task and schedule a fresh one.
                    Task { @MainActor [weak debugViewModel, accum, expiryHandle] in
                        expiryHandle.task?.cancel()
                        expiryHandle.task = nil
                        screen.receive(aesthetic: signal.remark)
                    debugViewModel?.aestheticRemark = signal.remark
                        let newTask = Task { [accum, weak debugViewModel] in
                            try? await Task.sleep(for: .seconds(aestheticRemarkExpirySeconds))
                            guard !Task.isCancelled else { return }
                            accum.update(aesthetic: AestheticSignal.nothingToSay)
                            await MainActor.run { [weak debugViewModel] in
                                screen.receive(aesthetic: nil)
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
                        screen.receive(aesthetic: nil)
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
        } onGroupPresence: { [accum] in accum.update(groupPresence: $0) }

        let feed = debugViewModel.makeTelemetryFeed(downstream: probe)
        orchestrator?.downstream = feed.bridge
        let adapterDownstream: any CameraFrameDelegate = orchestrator ?? feed.bridge
        let adapter = SceneGateAdapter(gate: sceneGate, downstream: adapterDownstream)
        // Reference verification needs fresh unchanged frames. The VLM has its own
        // cadence/budget gates and must sit before the scene novelty gate.
        vlmOrch.downstream = adapter
        let subjects = SubjectObservationMonitor(downstream: vlmOrch, onObservation: { [screen] observation in
            Task { @MainActor in screen.receive(observation) }
        }, onLivePose: { [screen, weak debugViewModel] observation in
            Task { @MainActor in
                debugViewModel?.subjectDetectionSummary = observation.detectionSummary
                if screen.receive(livePose: observation) { vlmOrch.requestReferenceVerification() }
            }
        })
        subjectMonitor = subjects
        let exposureMon = ExposureMonitor(downstream: subjects) { [weak debugViewModel, accum] signal in
            accum.update(exposure: signal)
            let label: String
            switch signal.level {
            case .ok:           label = "ok"
            case .underexposed: label = "under"
            case .overexposed:  label = "over"
            }
            Task { @MainActor [weak debugViewModel] in
                screen.receive(exposure: signal)
                debugViewModel?.exposureLevel = label
            }
        }

        vlmOrch.updateReferenceMotion(isSettled: false)
        vlmOrch.updateReferenceArmed(cameraScreen.isArmed)
        camera.delegate = exposureMon
        feed.start()
        camera.requestPermissionAndStart()

        blurMonitor = blurMon
        exposureMonitor = exposureMon
        framingMonitor = framingMon
        landmarkProbe = probe
        landmarkOrchestrator = orchestrator
        vlmOrchestrator = vlmOrch
        syncReferenceAnalysis()
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

        let monitor = TiltMonitor(onSettleChange: { [sceneGate, vlmOrch] settled in
            sceneGate.update(isSettled: settled)
            vlmOrch.updateReferenceMotion(isSettled: settled)
            if settled {
                settleTimer.recordSettle()
            }
        }, onReading: { reading in
            Task { @MainActor in screen.receive(motion: reading) }
        }) { [weak debugViewModel, accum] signal in
            accum.update(tilt: signal)
            Task { @MainActor [weak debugViewModel] in
                screen.receive(tilt: signal)
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
