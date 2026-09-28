import AVFoundation
import CoreMedia
import CoreVideo
import UIKit
import os

// MARK: - Sendable wrappers
private struct SendablePixelBuffer: @unchecked Sendable { let value: CVPixelBuffer }
private struct SendableUIImage: @unchecked Sendable { let value: UIImage }

// MARK: - VLMOrchestrator

/// Tier-2 VLM orchestrator: forwards frames downstream first (Tier-0 invariant),
/// then gates, then dispatches inference on `vlmQueue`.
/// All shared mutable state is `OSAllocatedUnfairLock`-protected (`@unchecked Sendable`).
public final class VLMOrchestrator: @unchecked Sendable, CameraFrameDelegate {

    public weak var downstream: (any CameraFrameDelegate)?

    // MARK: - Injected dependencies

    private let client: any VLMClient
    private let encodeLive: @Sendable (CVPixelBuffer) -> Data?
    private let encodeReference: @Sendable (UIImage) -> Data?
    private let suppressor: StaleSuppressor
    private let responseCache: VLMResponseCache
    private let onAestheticSignal: @Sendable (AestheticSignal) -> Void
    private let onRequestDispatched: (@Sendable () -> Void)?
    private let onRequestCompleted: (@Sendable () -> Void)?
    private let onResponseDiscarded: (@Sendable () -> Void)?

    private let vlmQueue = DispatchQueue(
        label: VLMOrchestratorConstants.queueLabel,
        qos: .utility
    )

    // MARK: - Lock-protected mutable state

    private let isBusy = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let gateLock: OSAllocatedUnfairLock<VLMRequestGate>
    private let bodyHintLock = OSAllocatedUnfairLock<BodyHint>(initialState: .goodBody)
    private let currentSignatureLock = OSAllocatedUnfairLock<SceneSignature?>(initialState: nil)
    private let failureLock = OSAllocatedUnfairLock<VLMFailureState>(
        initialState: VLMFailureState()
    )
    private let statsLock = OSAllocatedUnfairLock<VLMSessionStats>(
        initialState: VLMSessionStats()
    )

    private let referenceCoordinator = ReferenceAnalysisCoordinator()
    // Legacy clients may gate frames upstream. The camera composition root supplies
    // real motion state before starting capture for both analysis modes.
    private let motionSettledLock = OSAllocatedUnfairLock(initialState: true)
    private let onReferenceAnalysis: (@Sendable (ReferenceAnalysisEvent) -> Void)?
    private let clock: @Sendable () -> TimeInterval
    static let maxConsecutiveFailures: Int = 3
    public static let backoffBaseSeconds: TimeInterval = 2.0
    private let instanceBackoffBase: TimeInterval

    static let maxRetryAttempts: Int = 2
    /// 1 s; multiplied by attempt number (1×, 2×) for linear backoff.
    static let retryBaseDelayNanoseconds: UInt64 = 1_000_000_000
    private let retrySleep: @Sendable (UInt64) async -> Void
    // MARK: - Init

    init(
        client: any VLMClient,
        encodeLive: @escaping @Sendable (CVPixelBuffer) -> Data? = { FrameEncoder.encode(pixelBuffer: $0) },
        encodeReference: @escaping @Sendable (UIImage) -> Data? = { FrameEncoder.encodeUIImage($0) },
        gate: VLMRequestGate = VLMRequestGate(),
        suppressor: StaleSuppressor = StaleSuppressor(),
        responseCache: VLMResponseCache = VLMResponseCache(),
        backoffBaseSeconds: TimeInterval = VLMOrchestrator.backoffBaseSeconds,
        retrySleep: (@Sendable (UInt64) async -> Void)? = nil,
        onRequestDispatched: (@Sendable () -> Void)? = nil,
        onRequestCompleted: (@Sendable () -> Void)? = nil,
        onResponseDiscarded: (@Sendable () -> Void)? = nil,
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        onReferenceAnalysis: (@Sendable (ReferenceAnalysisEvent) -> Void)? = nil,
        onAestheticSignal: @escaping @Sendable (AestheticSignal) -> Void
    ) {
        self.clock = clock
        self.onReferenceAnalysis = onReferenceAnalysis
        self.client = client
        self.encodeLive = encodeLive
        self.encodeReference = encodeReference
        self.gateLock = OSAllocatedUnfairLock(initialState: gate)
        self.suppressor = suppressor
        self.responseCache = responseCache
        self.instanceBackoffBase = backoffBaseSeconds
        self.retrySleep = retrySleep ?? { ns in try? await Task.sleep(nanoseconds: ns) }
        self.onRequestDispatched = onRequestDispatched
        self.onRequestCompleted = onRequestCompleted
        self.onResponseDiscarded = onResponseDiscarded
        self.onAestheticSignal = onAestheticSignal
    }

    // MARK: - Public API

    public func update(bodyHint: BodyHint) {
        bodyHintLock.withLock { $0 = bodyHint }
    }

    public var sessionStats: VLMSessionStats { statsLock.withLock { $0 } }

    func setReferenceContext(sessionID: UUID?, generation: UInt64, image: UIImage?, consented: Bool, geometryRevision: UInt64) {
        if referenceCoordinator.setContext(sessionID: sessionID, generation: generation, image: image,
            consented: consented, geometryRevision: geometryRevision) { responseCache.invalidate() }
        let context = referenceCoordinator.snapshot
        if context.profile == nil {
            dispatchReference(pixelBuffer: nil, context: context, capturedAt: clock(), signature: nil)
        }
    }
    func updateReferenceMotion(isSettled: Bool) {
        motionSettledLock.withLock { $0 = isSettled }
        referenceCoordinator.updateMotion(isSettled: isSettled)
    }
    func updateReferenceArmed(_ armed: Bool) { referenceCoordinator.updateArmed(armed) }
    func requestReferenceVerification() { referenceCoordinator.requestVerification() }
    // Compatibility for older callers; production uses the atomic setter above.
    var referenceImage: UIImage? {
        get { referenceCoordinator.snapshot.image }
        set {
            let old = referenceCoordinator.snapshot
            setReferenceContext(sessionID: newValue == nil ? nil : (old.sessionID ?? UUID()),
                generation: old.generation &+ 1, image: newValue, consented: old.consented, geometryRevision: old.geometryRevision)
        }
    }
    var referenceModeConsented: Bool {
        get { referenceCoordinator.snapshot.consented }
        set {
            let old = referenceCoordinator.snapshot
            setReferenceContext(sessionID: old.sessionID, generation: old.generation &+ 1,
                image: old.image, consented: newValue, geometryRevision: old.geometryRevision)
        }
    }

    func invalidateCache() { responseCache.invalidate() }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // 1. Forward downstream FIRST — Tier-0 forwarding invariant, non-negotiable.
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        // 1b. Snapshot live scene signature pre-gate.
        let liveSignature = SceneSignature.compute(from: pixelBuffer)
        currentSignatureLock.withLock { $0 = liveSignature }
        if let invalidated = referenceCoordinator.invalidateComparison(for: liveSignature) {
            onReferenceAnalysis?(.invalidated(invalidated))
        }

        // 1c. On-device-only toggle — short-circuits before FrameEncoder runs.
        guard !VLMSettings.shared.isOnDeviceOnly else { return }

        // Any active reference suppresses generic uploads, including opted-out selections.
        let context = referenceCoordinator.snapshot
        if context.sessionID != nil {
            if context.profile == nil {
                dispatchReference(pixelBuffer: nil, context: context, capturedAt: clock(), signature: nil)
            } else if let capturedAt = capturedTime(timestamp), clock() - capturedAt < VLMOrchestratorConstants.comparisonFreshnessSeconds {
                dispatchReference(pixelBuffer: SendablePixelBuffer(value: pixelBuffer), context: context,
                    capturedAt: capturedAt, signature: liveSignature)
            }
            return
        }

        // 1d. Offline-degradation session disable — silent, no retry.
        guard !failureLock.withLock({ $0.isDisabledForSession }) else { return }

        // 1e. Backoff guard.
        guard Date() >= failureLock.withLock({ $0.backoffDeadline }) else { return }

        // 2. Compute SceneSignature.
        guard let signature = liveSignature else { return }

        // Reserve busy before consuming quota.
        guard isBusy.withLock({ busy in
            guard !busy else { return false }; busy = true; return true
        }) else { return }
        // 3. Gate check.
        let authorized = gateLock.withLock { gate in
            gate.isEligible(signature: signature, isSettled: motionSettledLock.withLock { $0 })
        }
        guard authorized else { isBusy.withLock { $0 = false }; return }

        let capturedAt = capturedTime(timestamp)
        let requestID = UUID()
        if let cached = responseCache.lookup(for: signature) {
            gateLock.withLock { $0.recordDelivery(signature: signature) }
            statsLock.withLock {
                $0.recordCacheHit()
                $0.begin(id: requestID, operation: .aesthetic, capturedAt: capturedAt, encodingSeconds: 0, cacheHit: true)
                $0.completed(id: requestID, at: clock(), outcome: .accepted)
            }
            onAestheticSignal(cached)
            isBusy.withLock { $0 = false }
            return
        }
        statsLock.withLock { $0.recordCacheMiss() }
        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        let hint = bodyHintLock.withLock { $0 }
        let epoch = context.epoch
        vlmQueue.async { [weak self] in
            self?.dispatchInference(pixelBuffer: wrapped, signature: signature, capturedBodyHint: hint,
                                    epoch: epoch, requestID: requestID, capturedAt: capturedAt)
        }
    }

    /// AVFoundation timestamps are host-clock seconds, never Unix time. Translate the
    /// observed age once at arrival; invalid/test timestamps remain explicitly unknown.
    private func capturedTime(_ timestamp: CMTime) -> TimeInterval? {
        guard timestamp.isValid, timestamp != .zero else { return nil }
        let age = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(timestamp)
        guard age.isFinite, age >= 0 else { return nil }
        return clock() - age
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }

    // MARK: - Private inference dispatch

    private func dispatchInference(pixelBuffer: SendablePixelBuffer, signature: SceneSignature,
                                   capturedBodyHint: BodyHint, epoch: UInt64, requestID: UUID,
                                   capturedAt: TimeInterval?) {
        @Sendable func valid() -> Bool {
            self.referenceCoordinator.snapshot.epoch == epoch &&
            self.referenceCoordinator.snapshot.sessionID == nil && !VLMSettings.shared.isOnDeviceOnly
        }
        guard valid() else { isBusy.withLock { $0 = false }; return }
        let tag = suppressor.makeTag(signature: signature, bodyHint: capturedBodyHint)
        let start = clock()
        guard let jpeg = encodeLive(pixelBuffer.value), valid() else { isBusy.withLock { $0 = false }; return }
        statsLock.withLock { $0.begin(id: requestID, operation: .aesthetic, capturedAt: capturedAt,
                                     encodingSeconds: max(0, clock() - start), cacheHit: false) }
        let task = Task { [weak self] in
            guard let self else { return }
            var outcome = VLMRequestMeasurement.Outcome.failed
            defer {
                statsLock.withLock { [outcome] in $0.completed(id: requestID, at: clock(), outcome: outcome) }
                isBusy.withLock { $0 = false }
                onRequestCompleted?()
            }
            guard valid(), !Task.isCancelled else { outcome = .stale; return }
            let request = VLMRequest(imageJPEG: jpeg, prompt: AestheticPrompt.v1)
            let inferenceTask = Task<VLMResponse?, Never> {
                do {
                    let response = try await self.analyzeWithRetry(request, requestID: requestID, signature: signature, epoch: epoch)
                    self.failureLock.withLock { $0.consecutiveFailures = 0; $0.backoffDeadline = .distantPast }
                    return response
                } catch {
                    if (error as? VLMError) != .cancelled && (error as? VLMError) != .rateLimited {
                        self.failureLock.withLock { state in
                            state.consecutiveFailures += 1
                            let exponent = min(Double(state.consecutiveFailures - 1), Double(Self.maxConsecutiveFailures - 1))
                            state.backoffDeadline = Date().addingTimeInterval(self.instanceBackoffBase * pow(2, exponent))
                            if state.consecutiveFailures >= Self.maxConsecutiveFailures { state.isDisabledForSession = true }
                        }
                    }
                    return nil
                }
            }
            let timeout = Task {
                try? await Task.sleep(nanoseconds: UInt64(VLMOrchestratorConstants.requestTimeoutSeconds * 1_000_000_000))
                if !Task.isCancelled { inferenceTask.cancel() }
            }
            defer { timeout.cancel() }
            let response = await withTaskCancellationHandler { await inferenceTask.value } onCancel: { inferenceTask.cancel() }
            guard valid(), !Task.isCancelled else { outcome = .stale; onResponseDiscarded?(); return }
            guard let response else { return }
            let signal = AestheticResponseParser.parse(response.text)
            guard let accepted = suppressor.evaluate(signal: signal, tag: tag,
                currentSignature: currentSignatureLock.withLock { $0 }, currentBodyHint: bodyHintLock.withLock { $0 }) else {
                outcome = .stale; onResponseDiscarded?(); return
            }
            outcome = .accepted
            onAestheticSignal(accepted)
            responseCache.store(accepted, for: signature)
        }
        referenceCoordinator.register(task, epoch: epoch)
    }

    private func dispatchReference(pixelBuffer: SendablePixelBuffer?, context: ReferenceAnalysisCoordinator.Snapshot,
                                   capturedAt: TimeInterval, signature: SceneSignature?) {
        let isProfile = context.profile == nil
        guard !VLMSettings.shared.isOnDeviceOnly, let sessionID = context.sessionID,
              let image = context.image, context.consented,
              (isProfile || (referenceCoordinator.isSettled && pixelBuffer != nil && signature != nil)),
              referenceCoordinator.canSchedule(now: clock(), signature: signature),
              gateLock.withLock({ $0.isEligible(signature: signature, isSettled: true, allowsVerification: true) }) else { return }
        guard isBusy.withLock({ busy in guard !busy else { return false }; busy = true; return true }) else { return }
        let envelope = ReferenceEnvelope(sessionID: sessionID, generation: context.generation,
            requestID: UUID(), capturedAt: capturedAt, geometryRevision: context.geometryRevision)
        let wrappedImage = SendableUIImage(value: image)
        vlmQueue.async { [weak self] in
            guard let self else { return }
            @Sendable func valid() -> Bool {
                let current = self.referenceCoordinator.snapshot
                guard current.epoch == context.epoch, current.consented, !VLMSettings.shared.isOnDeviceOnly else { return false }
                if isProfile {
                    return self.clock() >= capturedAt && self.clock() - capturedAt < VLMOrchestratorConstants.requestTimeoutSeconds
                }
                return self.referenceCoordinator.accepts(envelope, now: self.clock(), cloudAllowed: true)
            }
            let start = self.clock()
            guard valid() else { self.isBusy.withLock { $0 = false }; return }
            let referenceJPEG: Data
            if let cached = context.referenceJPEG { referenceJPEG = cached }
            else {
                guard let encoded = self.encodeReference(wrappedImage.value), valid(),
                      self.referenceCoordinator.storeReferenceJPEG(encoded, epoch: context.epoch) else {
                    self.isBusy.withLock { $0 = false }; return
                }
                referenceJPEG = encoded
            }
            var liveJPEG = Data()
            if !isProfile {
                guard let pixelBuffer, let encoded = self.encodeLive(pixelBuffer.value), valid() else {
                    self.isBusy.withLock { $0 = false }; return
                }
                liveJPEG = encoded
            }
            guard valid(), self.referenceCoordinator.beginRequest(envelope.requestID, epoch: context.epoch) else {
                self.isBusy.withLock { $0 = false }; return
            }
            let operation: VLMOperation = isProfile ? .referenceProfile : .referenceComparison
            self.statsLock.withLock { $0.begin(id: envelope.requestID, operation: operation, capturedAt: capturedAt,
                                              encodingSeconds: max(0, self.clock() - start), cacheHit: false) }
            let encodedLive = liveJPEG
            let task = Task { [weak self] in
                guard let self else { return }
                var outcome = VLMRequestMeasurement.Outcome.failed
                defer {
                    self.statsLock.withLock { [outcome] in $0.completed(id: envelope.requestID, at: self.clock(), outcome: outcome) }
                    self.referenceCoordinator.finishRequest(envelope.requestID)
                    self.isBusy.withLock { $0 = false }
                    self.onRequestCompleted?()
                }
                guard !Task.isCancelled, valid(), isProfile || self.referenceCoordinator.isSettled else { outcome = .stale; return }
                let profileJSON = context.profile.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                let request = VLMRequest(operation: operation, imageJPEG: encodedLive,
                    referenceImageJPEG: referenceJPEG, profileJSON: profileJSON,
                    prompt: isProfile ? ReferenceAnalysisPrompt.profile : ReferenceAnalysisPrompt.comparison)
                guard valid(), !Task.isCancelled else { outcome = .stale; return }
                guard self.gateLock.withLock({ $0.consumeNetworkAttempt(signature: signature) }) else {
                    if valid(), self.referenceCoordinator.shouldReportBudget() {
                        self.onReferenceAnalysis?(.unavailable(envelope, .budgetExhausted))
                    }
                    return
                }
                self.referenceCoordinator.recordDispatch(now: self.clock(), signature: signature)
                self.statsLock.withLock { $0.dispatched(id: envelope.requestID, at: self.clock()) }
                self.onRequestDispatched?()
                if let profile = context.profile { self.onReferenceAnalysis?(.profile(envelope, profile)) }
                do {
                    let response = try await self.client.analyze(request)
                    guard valid(), !Task.isCancelled else { outcome = .stale; self.onResponseDiscarded?(); return }
                    let data = Data(response.text.utf8)
                    if isProfile {
                        let profile = try ReferenceAnalysisParser.parseProfile(data)
                        self.referenceCoordinator.store(profile, epoch: context.epoch)
                        guard valid() else { outcome = .stale; return }
                        self.onReferenceAnalysis?(.profile(envelope, profile))
                    } else {
                        let comparison = try ReferenceAnalysisParser.parseComparison(data)
                        guard valid(), let signature else { outcome = .stale; return }
                        let stillCurrent = self.currentSignatureLock.withLock { current in
                            guard let current, !current.isMateriallyDifferent(from: signature) else { return false }
                            self.referenceCoordinator.recordComparison(envelope, signature: signature, epoch: context.epoch,
                                                                      hasAction: comparison.action != nil)
                            return true
                        }
                        guard stillCurrent else { outcome = .stale; self.onResponseDiscarded?(); return }
                        self.onReferenceAnalysis?(.comparison(envelope, comparison))
                    }
                    outcome = .accepted
                } catch {
                    guard valid(), !Task.isCancelled else { outcome = .stale; return }
                    let failure: ReferenceAnalysisFailure
                    if let error = error as? VLMError {
                        switch error {
                        case .networkFailure: failure = .offline
                        case .decodingFailure: failure = .invalidResponse
                        case .rateLimited: failure = .budgetExhausted
                        default: failure = .serviceUnavailable
                        }
                    } else { failure = .invalidResponse }
                    self.onReferenceAnalysis?(.unavailable(envelope, failure))
                }
            }
            self.referenceCoordinator.register(task, epoch: context.epoch)
            Task {
                let lifetime = isProfile ? VLMOrchestratorConstants.requestTimeoutSeconds : VLMOrchestratorConstants.comparisonFreshnessSeconds
                let remaining = max(0, lifetime - (self.clock() - capturedAt))
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                if self.referenceCoordinator.finishRequest(envelope.requestID) {
                    task.cancel()
                    let current = self.referenceCoordinator.snapshot
                    if current.epoch == context.epoch, current.consented, !VLMSettings.shared.isOnDeviceOnly {
                        self.onReferenceAnalysis?(.unavailable(envelope, .timedOut))
                    }
                }
            }
        }
    }

    // MARK: - Retry helper

    /// Retries on `.networkFailure` / HTTP 502 up to `maxRetryAttempts` times (1 s, then 2 s).
    /// 503 and all other errors surface immediately without retry.
    private func analyzeWithRetry(_ request: VLMRequest, requestID: UUID, signature: SceneSignature, epoch: UInt64) async throws(VLMError) -> VLMResponse {
        var attempt = 0
        while true {
            do {
                guard referenceCoordinator.snapshot.epoch == epoch, referenceCoordinator.snapshot.sessionID == nil, !VLMSettings.shared.isOnDeviceOnly, !Task.isCancelled else { throw VLMError.cancelled }
                guard gateLock.withLock({ [attempt] in attempt == 0 ? $0.consumeNetworkAttempt(signature: signature) : $0.consumeRetry() }) else { throw VLMError.rateLimited }
                statsLock.withLock { $0.dispatched(id: requestID, at: clock()) }
                if attempt == 0 { onRequestDispatched?() }
                return try await client.analyze(request)
            } catch let error as VLMError {
                let transient: Bool
                switch error {
                case .networkFailure:           transient = true
                case .httpError(502, _):        transient = true
                default:                        transient = false
                }
                guard transient, attempt < Self.maxRetryAttempts else { throw error }
                attempt += 1
                await retrySleep(Self.retryBaseDelayNanoseconds * UInt64(attempt))
            } catch {
                throw VLMError.networkFailure(error.localizedDescription)
            }
        }
    }
}
