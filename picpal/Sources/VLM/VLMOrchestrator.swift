import AVFoundation
import CoreMedia
import CoreVideo
import os

// MARK: - Sendable wrapper

private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

// MARK: - Constants

private enum VLMOrchestratorConstants {
    static let queueLabel             = "com.picpal.vlm.orchestrator"
    /// Hard upper-bound on a single VLM round-trip. Timed-out requests never produce a cue.
    static let requestTimeoutSeconds: TimeInterval = 10.0
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
    private let onAestheticSignal: @Sendable (AestheticSignal) -> Void

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

    // MARK: - Init

    /// Creates a `VLMOrchestrator`.
    ///
    /// - Parameters:
    ///   - client: VLM back-end (default: `AnthropicVLMClient` targeting the local proxy).
    ///   - gate: Four-gate request authoriser. Defaults to a fresh `VLMRequestGate`.
    ///   - suppressor: Stale-response filter. Defaults to a fresh `StaleSuppressor`.
    ///   - onAestheticSignal: Called on any thread when a valid `AestheticSignal` arrives.
    public init(
        client: any VLMClient,
        gate: VLMRequestGate = VLMRequestGate(),
        suppressor: StaleSuppressor = StaleSuppressor(),
        onAestheticSignal: @escaping @Sendable (AestheticSignal) -> Void
    ) {
        self.client = client
        self.gateLock = OSAllocatedUnfairLock(initialState: gate)
        self.suppressor = suppressor
        self.onAestheticSignal = onAestheticSignal
    }

    // MARK: - Public API

    /// Update the body hint used by the stale-suppressor for response matching.
    ///
    /// Call whenever `BodySignal.hint` changes so that in-flight responses can be
    /// correctly invalidated when body context shifts mid-flight.
    public func update(bodyHint: BodyHint) {
        bodyHintLock.withLock { $0 = bodyHint }
    }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // 1. Forward downstream FIRST — Tier-0 forwarding invariant, non-negotiable.
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        // 2. Compute SceneSignature (cheap 16×16 grid walk; safe on the camera queue).
        guard let signature = SceneSignature.compute(from: pixelBuffer) else { return }

        // 3. Gate check (cadence + novelty + settle + budget).
        //    `isSettled: true` — VLMOrchestrator sits downstream of SceneGateAdapter
        //    which already filters on scene settle.
        let authorized = gateLock.withLock { gate in
            gate.shouldRequest(signature: signature, isSettled: true)
        }
        guard authorized else { return }

        // 4. Drop-if-busy — prevents pool exhaustion and concurrent requests.
        //    `isBusy` is set synchronously here; cleared by the inference Task.
        guard isBusy.withLock({ busy in
            guard !busy else { return false }
            busy = true
            return true
        }) else { return }

        // 5. Dispatch heavy work off the camera queue.
        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        let capturedBodyHint = bodyHintLock.withLock { $0 }

        vlmQueue.async { [weak self] in
            guard let self else { return }

            // 5a. Snapshot the request tag before encoding begins.
            let tag = suppressor.makeTag(signature: signature, bodyHint: capturedBodyHint)

            // 5b. Encode to JPEG (CPU-intensive; runs on vlmQueue).
            guard let jpegData = FrameEncoder.encode(pixelBuffer: wrapped.value) else {
                isBusy.withLock { $0 = false }
                return
            }

            // 5c–f. Run async inference with hard timeout.
            Task { [weak self] in
                guard let self else { return }
                defer { isBusy.withLock { $0 = false } }

                let request = VLMRequest(imageJPEG: jpegData, prompt: AestheticPrompt.v1)

                // Inner task: actual network call — cancelled on timeout.
                let inferenceTask = Task<VLMResponse?, Never> {
                    return try? await self.client.analyze(request)
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

                // 5e. Evaluate staleness against current scene + body state.
                let currentSig = SceneSignature.compute(from: wrapped.value)
                let currentHint = bodyHintLock.withLock { $0 }
                guard let valid = suppressor.evaluate(
                    signal: signal,
                    tag: tag,
                    currentSignature: currentSig,
                    currentBodyHint: currentHint
                ) else { return }

                // 5f. Emit valid signal upstream.
                onAestheticSignal(valid)
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
