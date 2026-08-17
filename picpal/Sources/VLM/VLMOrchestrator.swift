import AVFoundation
import CoreMedia
import CoreVideo
import os

// MARK: - Sendable wrapper

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

// MARK: - VLMOrchestrator

/// Tier-2 VLM orchestrator. Sits after `LandmarkOrchestrator` in the pipeline.
///
/// Forwards frames downstream FIRST (Tier-0 forwarding invariant), then gates,
/// then dispatches inference off the camera queue.
///
/// ## Threading
/// JPEG encoding and Task dispatch run on a private serial `vlmQueue` (QoS `.utility`).
/// The actual network call runs on Swift's cooperative thread pool inside a `Task`.
/// The drop-if-busy flag (`isBusy`) prevents CVPixelBuffer pool exhaustion and is
/// set synchronously before any async dispatch.
///
/// ## Swift 6
/// `@unchecked Sendable` — all shared mutable state is protected by
/// `OSAllocatedUnfairLock`. Delegate methods are `nonisolated`.
public final class VLMOrchestrator: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Downstream pipeline delegate

    /// Set once before inference begins; weak to avoid retain cycles.
    public weak var downstream: (any CameraFrameDelegate)?

    // MARK: - Injected dependencies

    private let client: any VLMClient
    private let suppressor: StaleSuppressor
    private let responseCache: VLMResponseCache
    private let onAestheticSignal: @Sendable (AestheticSignal) -> Void

    /// Called before dispatching to `vlmQueue` — use to set an in-flight UI indicator.
    private let onRequestDispatched: (@Sendable () -> Void)?
    /// Called at every inference-Task exit (success, discard, timeout, error).
    private let onRequestCompleted: (@Sendable () -> Void)?
    /// Called when `StaleSuppressor.evaluate` discards a response (scene changed).
    private let onResponseDiscarded: (@Sendable () -> Void)?

    // MARK: - Private serial queue

    private let vlmQueue = DispatchQueue(
        label: VLMOrchestratorConstants.queueLabel,
        qos: .utility
    )

    // MARK: - Lock-protected mutable state

    /// Drop-if-busy flag — same pattern as `LandmarkOrchestrator`.
    /// Set synchronously before `vlmQueue.async`; cleared by the inference `Task`.
    private let isBusy = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Mutable `VLMRequestGate` (value type — needs a lock).
    private let gateLock: OSAllocatedUnfairLock<VLMRequestGate>

    /// Current body-framing hint forwarded to the stale-suppressor.
    private let bodyHintLock = OSAllocatedUnfairLock<BodyHint>(initialState: .goodBody)

    /// Most-recent `SceneSignature` from the camera queue. Updated every frame (pre-gate)
    /// so suppressor.evaluate sees the live scene, not the stale retained pixel buffer.
    private let currentSignatureLock = OSAllocatedUnfairLock<SceneSignature?>(initialState: nil)

    /// Offline-degradation failure tracking.
    private let failureLock = OSAllocatedUnfairLock<VLMFailureState>(
        initialState: VLMFailureState()
    )

    /// Per-session VLM cache hit/miss counters.
    private let statsLock = OSAllocatedUnfairLock<VLMSessionStats>(
        initialState: VLMSessionStats()
    )

    /// Placeholder for future reference-image mode. When non-nil, cache is bypassed.
    private let referenceImageLock = OSAllocatedUnfairLock<Data?>(initialState: nil)

    // MARK: - Named constants

    /// Number of consecutive VLM failures that permanently disables Tier 2
    /// for the remainder of the session. Kept internal so tests can reference it.
    static let maxConsecutiveFailures: Int = 3

    /// Base delay (seconds) for exponential backoff after each VLM failure.
    /// Produces 2s → 4s → 8s windows before the third failure disables the session.
    public static let backoffBaseSeconds: TimeInterval = 2.0

    // MARK: - Per-instance backoff base (injectable for testing)

    /// Backoff base used by this instance. Tests may inject a near-zero value.
    private let instanceBackoffBase: TimeInterval

    // MARK: - Init

    /// Creates a `VLMOrchestrator`.
    ///
    /// - Parameters:
    ///   - client: VLM back-end (default: `AnthropicVLMClient` targeting the local proxy).
    ///   - gate: Four-gate request authoriser. Defaults to a fresh `VLMRequestGate`.
    ///   - suppressor: Stale-response filter. Defaults to a fresh `StaleSuppressor`.
    ///   - responseCache: In-session LRU cache. Defaults to a fresh `VLMResponseCache`.
    ///   - onAestheticSignal: Called on any thread when a valid `AestheticSignal` arrives.
    // Internal: VLMResponseCache default parameter prevents public init under Swift 6 access rules.
    init(
        client: any VLMClient,
        gate: VLMRequestGate = VLMRequestGate(),
        suppressor: StaleSuppressor = StaleSuppressor(),
        responseCache: VLMResponseCache = VLMResponseCache(),
        backoffBaseSeconds: TimeInterval = VLMOrchestrator.backoffBaseSeconds,
        onRequestDispatched: (@Sendable () -> Void)? = nil,
        onRequestCompleted: (@Sendable () -> Void)? = nil,
        onResponseDiscarded: (@Sendable () -> Void)? = nil,
        onAestheticSignal: @escaping @Sendable (AestheticSignal) -> Void
    ) {
        self.client = client
        self.gateLock = OSAllocatedUnfairLock(initialState: gate)
        self.suppressor = suppressor
        self.responseCache = responseCache
        self.instanceBackoffBase = backoffBaseSeconds
        self.onRequestDispatched = onRequestDispatched
        self.onRequestCompleted = onRequestCompleted
        self.onResponseDiscarded = onResponseDiscarded
        self.onAestheticSignal = onAestheticSignal
    }

    // MARK: - Public API

    /// Update the body hint used by the stale-suppressor for response matching.
    public func update(bodyHint: BodyHint) {
        bodyHintLock.withLock { $0 = bodyHint }
    }

    /// Current VLM session statistics (cache hits, misses). Safe to read from any thread.
    var sessionStats: VLMSessionStats { statsLock.withLock { $0 } }

    /// Reference image data for future reference-mode support.
    /// When non-nil, the response cache is bypassed so every frame hits the VLM.
    var referenceImage: Data? {
        get { referenceImageLock.withLock { $0 } }
        set { referenceImageLock.withLock { $0 = newValue } }
    }

    /// Invalidate all cached VLM responses. Call on app background or session end.
    func invalidateCache() { responseCache.invalidate() }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // 1. Forward downstream FIRST — Tier-0 forwarding invariant, non-negotiable.
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        // 1b. Snapshot live scene signature pre-gate so suppressor.evaluate has the
        //     actual current scene at response time, not the retained pixel buffer.
        //     Computed outside the @Sendable closure to avoid capturing non-Sendable CVPixelBuffer.
        let liveSignature = SceneSignature.compute(from: pixelBuffer)
        currentSignatureLock.withLock { $0 = liveSignature }

        // 1c. On-device-only toggle — short-circuits before FrameEncoder runs.
        guard !VLMSettings.shared.isOnDeviceOnly else { return }

        // 1d. Offline-degradation session disable — silent, no retry.
        guard !failureLock.withLock({ $0.isDisabledForSession }) else { return }

        // 1e. Backoff guard — suppress frames within the exponential backoff window.
        guard Date() >= failureLock.withLock({ $0.backoffDeadline }) else { return }

        // 2. Compute SceneSignature (cheap 16×16 grid walk; safe on the camera queue).
        guard let signature = SceneSignature.compute(from: pixelBuffer) else { return }

        // 3. Gate check (cadence + novelty + settle + budget).
        //    `isSettled: true` — VLMOrchestrator sits downstream of SceneGateAdapter.
        let authorized = gateLock.withLock { gate in
            gate.shouldRequest(signature: signature, isSettled: true)
        }
        guard authorized else { return }

        // 3a. Cache lookup — skipped when reference image is active.
        if referenceImageLock.withLock({ $0 == nil }),
           let cached = responseCache.lookup(for: signature) {
            onAestheticSignal(cached)
            statsLock.withLock { $0.recordCacheHit() }
            return
        }

        // 3b. Cache miss — counted here so all gate-passing frames are accounted for,
        //     regardless of whether the request is later dropped (busy, error, suppressed).
        statsLock.withLock { $0.recordCacheMiss() }

        // 4. Drop-if-busy — prevents pool exhaustion and concurrent requests.
        //    `isBusy` is set synchronously here; cleared by the inference Task.
        guard isBusy.withLock({ busy in
            guard !busy else { return false }
            busy = true
            return true
        }) else { return }

        // 5. Notify the UI that a request is about to be dispatched.
        onRequestDispatched?()

        // 5a. Dispatch heavy work off the camera queue.
        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        let capturedBodyHint = bodyHintLock.withLock { $0 }

        vlmQueue.async { [weak self] in
            guard let self else { return }

            // 5b. Snapshot the request tag before encoding begins.
            let tag = suppressor.makeTag(signature: signature, bodyHint: capturedBodyHint)

            // 5c. Encode to JPEG (CPU-intensive; runs on vlmQueue).
            guard let jpegData = FrameEncoder.encode(pixelBuffer: wrapped.value) else {
                isBusy.withLock { $0 = false }
                return
            }

            // 5d–g. Run async inference with hard timeout.
            Task { [weak self] in
                guard let self else { return }
                defer { isBusy.withLock { $0 = false } }
                defer { onRequestCompleted?() }

                let request = VLMRequest(imageJPEG: jpegData, prompt: AestheticPrompt.v1)

                // Inner task: actual network call — cancelled on timeout.
                // Tracks success/failure for offline-degradation accounting.
                let inferenceTask = Task<VLMResponse?, Never> {
                    do {
                        let r = try await self.client.analyze(request)
                        // Success — reset consecutive failure counter and backoff deadline.
                        self.failureLock.withLock { state in
                            state.consecutiveFailures = 0
                            state.backoffDeadline = Date.distantPast
                        }
                        return r
                    } catch {
                        // Any VLMError: increment failure counter; set exponential backoff;
                        // disable session permanently at threshold.
                        self.failureLock.withLock { state in
                            state.consecutiveFailures += 1
                            let exponent = min(
                                Double(state.consecutiveFailures - 1),
                                Double(Self.maxConsecutiveFailures - 1)
                            )
                            state.backoffDeadline = Date().addingTimeInterval(
                                self.instanceBackoffBase * pow(2.0, exponent)
                            )
                            if state.consecutiveFailures >= Self.maxConsecutiveFailures {
                                state.isDisabledForSession = true
                            }
                        }
                        return nil
                    }
                }

                // Timeout task: cancels inference after requestTimeoutSeconds.
                let timeoutNs = UInt64(VLMOrchestratorConstants.requestTimeoutSeconds * 1_000_000_000)
                let timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    inferenceTask.cancel()
                }
                defer { timeoutTask.cancel() }

                // Wait for response (or cancellation/timeout → nil).
                guard let response = await inferenceTask.value else { return }

                // 5d. Parse the plain-text VLM response.
                let signal = AestheticResponseParser.parse(response.text)

                // 5e. Evaluate staleness: read live sig from lock, not the stale buffer.
                let currentSig = currentSignatureLock.withLock { $0 }
                let currentHint = bodyHintLock.withLock { $0 }
                guard let valid = suppressor.evaluate(
                    signal: signal,
                    tag: tag,
                    currentSignature: currentSig,
                    currentBodyHint: currentHint
                ) else {
                    onResponseDiscarded?()
                    return
                }

                // 5f. Emit valid signal and cache the response.
                onAestheticSignal(valid)
                responseCache.store(valid, for: signature)
            }
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }
}
