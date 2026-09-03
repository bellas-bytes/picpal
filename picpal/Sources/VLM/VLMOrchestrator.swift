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

    /// Reference image for two-image VLM mode. When non-nil, the M5 cache is bypassed.
    private let referenceImageLock = OSAllocatedUnfairLock<SendableUIImage?>(initialState: nil)

    /// Per-reference consent flag. Must be `true` before reference-image cloud calls are made.
    /// Does NOT affect `VLMSettings.shared.isOnDeviceOnly`.
    private let referenceModeConsentedLock = OSAllocatedUnfairLock<Bool>(initialState: false)
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
        gate: VLMRequestGate = VLMRequestGate(),
        suppressor: StaleSuppressor = StaleSuppressor(),
        responseCache: VLMResponseCache = VLMResponseCache(),
        backoffBaseSeconds: TimeInterval = VLMOrchestrator.backoffBaseSeconds,
        retrySleep: (@Sendable (UInt64) async -> Void)? = nil,
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

    var sessionStats: VLMSessionStats { statsLock.withLock { $0 } }

    /// Optional reference image for two-image VLM mode (bypasses M5 cache; never persisted).
    var referenceImage: UIImage? {
        get { referenceImageLock.withLock { $0?.value } }
        set { referenceImageLock.withLock { $0 = newValue.map(SendableUIImage.init) } }
    }

    /// Session-scoped consent flag; suppresses reference-image cloud calls when `false`.
    var referenceModeConsented: Bool {
        get { referenceModeConsentedLock.withLock { $0 } }
        set { referenceModeConsentedLock.withLock { $0 = newValue } }
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

        // 1c. On-device-only toggle — short-circuits before FrameEncoder runs.
        guard !VLMSettings.shared.isOnDeviceOnly else { return }

        // 1d. Offline-degradation session disable — silent, no retry.
        guard !failureLock.withLock({ $0.isDisabledForSession }) else { return }

        // 1e. Backoff guard.
        guard Date() >= failureLock.withLock({ $0.backoffDeadline }) else { return }

        // 2. Compute SceneSignature.
        guard let signature = SceneSignature.compute(from: pixelBuffer) else { return }

        // 3. Gate check.
        let authorized = gateLock.withLock { gate in
            gate.shouldRequest(signature: signature, isSettled: true)
        }
        guard authorized else { return }

        // 3a. Snapshot reference-mode state before deciding cache path.
        let capturedRefImage = referenceImageLock.withLock { $0 }
        let capturedConsented = referenceModeConsentedLock.withLock { $0 }

        // 3b. Cache lookup — skipped when reference image is active.
        if capturedRefImage == nil,
           let cached = responseCache.lookup(for: signature) {
            onAestheticSignal(cached)
            statsLock.withLock { $0.recordCacheHit() }
            return
        }

        // 3c. Cache miss counter — only for non-reference-mode frames.
        if capturedRefImage == nil {
            statsLock.withLock { $0.recordCacheMiss() }
        }

        // 4. Drop-if-busy.
        guard isBusy.withLock({ busy in
            guard !busy else { return false }
            busy = true
            return true
        }) else { return }

        // 5. Notify UI.
        onRequestDispatched?()

        // 5a. Dispatch heavy work off the camera queue.
        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        let capturedBodyHint = bodyHintLock.withLock { $0 }

        vlmQueue.async { [weak self] in
            guard let self else { return }
            dispatchInference(
                pixelBuffer: wrapped,
                signature: signature,
                capturedRefImage: capturedRefImage,
                capturedConsented: capturedConsented,
                capturedBodyHint: capturedBodyHint
            )
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }

    // MARK: - Private inference dispatch

    private func dispatchInference(
        pixelBuffer: SendablePixelBuffer,
        signature: SceneSignature,
        capturedRefImage: SendableUIImage?,
        capturedConsented: Bool,
        capturedBodyHint: BodyHint
    ) {
        let tag = suppressor.makeTag(signature: signature, bodyHint: capturedBodyHint)

        // Determine encode path: reference mode or standard.
        let encodedLive: Data
        let encodedReference: Data?
        let prompt: String
        let isReferenceMode: Bool

        if let refImg = capturedRefImage {
            // Reference mode: check consent BEFORE FrameEncoder runs.
            guard capturedConsented else {
                isBusy.withLock { $0 = false }
                return
            }
            guard let pair = FrameEncoder.encode(
                pixelBuffer: pixelBuffer.value, referenceImage: refImg.value
            ) else {
                isBusy.withLock { $0 = false }
                return
            }
            encodedLive = pair.liveData
            encodedReference = pair.referenceData
            prompt = VLMPrompt.referenceMode
            isReferenceMode = true
        } else {
            guard let jpegData = FrameEncoder.encode(pixelBuffer: pixelBuffer.value) else {
                isBusy.withLock { $0 = false }
                return
            }
            encodedLive = jpegData
            encodedReference = nil
            prompt = AestheticPrompt.v1
            isReferenceMode = false
        }

        // 5b-g. Unified async inference Task.
        Task { [weak self] in
            guard let self else { return }
            defer { isBusy.withLock { $0 = false } }
            defer { onRequestCompleted?() }

            let request = VLMRequest(
                imageJPEG: encodedLive,
                referenceImageJPEG: encodedReference,
                prompt: prompt
            )

            let inferenceTask = Task<VLMResponse?, Never> {
                do {
                    let r = try await self.analyzeWithRetry(request)
                    self.failureLock.withLock { state in
                        state.consecutiveFailures = 0
                        state.backoffDeadline = Date.distantPast
                    }
                    return r
                } catch {
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

            let timeoutNs = UInt64(
                VLMOrchestratorConstants.requestTimeoutSeconds * 1_000_000_000
            )
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                inferenceTask.cancel()
            }
            defer { timeoutTask.cancel() }

            guard let response = await inferenceTask.value else { return }

            let signal = AestheticResponseParser.parse(response.text)

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

            onAestheticSignal(valid)
            // Cache the response only when not in reference mode.
            if !isReferenceMode {
                responseCache.store(valid, for: signature)
            }
        }
    }

    // MARK: - Retry helper

    /// Retries on `.networkFailure` / HTTP 502 up to `maxRetryAttempts` times (1 s, then 2 s).
    /// 503 and all other errors surface immediately without retry.
    private func analyzeWithRetry(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        var attempt = 0
        while true {
            do {
                return try await client.analyze(request)
            } catch {
                let transient: Bool
                switch error {
                case .networkFailure:           transient = true
                case .httpError(502, _):        transient = true
                default:                        transient = false
                }
                guard transient, attempt < Self.maxRetryAttempts else { throw error }
                attempt += 1
                await retrySleep(Self.retryBaseDelayNanoseconds * UInt64(attempt))
            }
        }
    }
}
