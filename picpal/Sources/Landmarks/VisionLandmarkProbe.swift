import AVFoundation
import CoreMedia
import CoreVideo
import Vision
import os

// MARK: - Sendable bridge

/// Wraps `CVPixelBuffer` (a non-Sendable Core Foundation type) so it can cross
/// isolation boundaries safely. The caller is responsible for ensuring the buffer
/// is not mutated from another thread while the wrapper is in flight — which
/// `probeQueue`'s serial dispatch guarantees here.
private struct SendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

/// Runs three Vision landmark requests against each camera frame and reports
/// per-model and combined mean latencies via `onProbeStats`.
///
/// ## Purpose
/// This is a **measurement harness** for the M0-5 spike. It answers whether
/// body-pose + hand-pose + face-mesh can fit inside the 150 ms Tier-0.5 budget.
///
/// ## Threading
/// Frame callbacks arrive on the camera's frame queue. Vision work is
/// dispatched to a dedicated serial `probeQueue` so the camera queue is
/// never blocked. Each Vision request is run sequentially (not concurrently)
/// to measure realistic worst-case combined latency.
///
/// ## Sendable
/// `VisionLandmarkProbe` is `@unchecked Sendable`. All mutable state is
/// protected by `OSAllocatedUnfairLock`. The four `FrameTimer` actors are
/// themselves `Sendable`.
public final class VisionLandmarkProbe: @unchecked Sendable, CameraFrameDelegate {

    // MARK: - Constants

    private enum ProbeConstants {
        static let queueLabel = "com.picpal.landmarks.probe"
        static let orientation: CGImagePropertyOrientation = .up
    }

    // MARK: - Serial work queue

    private let probeQueue = DispatchQueue(
        label: ProbeConstants.queueLabel,
        qos: .userInitiated
    )

    // MARK: - Per-model timers

    private let bodyPoseTimer = FrameTimer()
    private let handPoseTimer = FrameTimer()
    private let faceMeshTimer = FrameTimer()
    private let combinedTimer  = FrameTimer()

    // MARK: - Protected state

    private let enabledLock: OSAllocatedUnfairLock<Bool>
    private let frameCountLock: OSAllocatedUnfairLock<Int>

    // MARK: - Callback

    private let onProbeStats: @Sendable (LandmarkProbeStats) -> Void

    private let logger = Logger(subsystem: "com.picpal", category: "VisionLandmarkProbe")

    // MARK: - Downstream chaining

    private weak var downstream: (any CameraFrameDelegate)?

    // MARK: - Init

    /// Create a probe.
    ///
    /// - Parameters:
    ///   - isEnabled: When `false` the probe ignores all incoming frames.
    ///     Toggle at any time via the `isEnabled` property.
    ///   - downstream: Next pipeline delegate; receives every frame regardless of
    ///     the `isEnabled` state, so downstream processing is never gated by Vision.
    ///   - onProbeStats: Called (off-main, on the Swift concurrency executor)
    ///     after each frame with updated rolling statistics. Dispatch to
    ///     `@MainActor` inside this closure to update UI.
    public init(
        isEnabled: Bool = true,
        downstream: (any CameraFrameDelegate)? = nil,
        onProbeStats: @escaping @Sendable (LandmarkProbeStats) -> Void
    ) {
        self.enabledLock    = OSAllocatedUnfairLock(initialState: isEnabled)
        self.frameCountLock = OSAllocatedUnfairLock(initialState: 0)
        self.downstream     = downstream
        self.onProbeStats   = onProbeStats
    }

    // MARK: - Public API

    /// Toggle Vision processing on/off. Thread-safe; may be set from any context.
    public var isEnabled: Bool {
        get { enabledLock.withLock { $0 } }
        set { enabledLock.withLock { $0 = newValue } }
    }

    // MARK: - CameraFrameDelegate

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        // Forward to downstream unconditionally — isEnabled only gates Vision work.
        downstream?.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)

        guard enabledLock.withLock({ $0 }) else { return }

        // Wrap in @unchecked Sendable so the non-Sendable CVBuffer type can
        // cross into the probeQueue closure. ARC retains the buffer for us.
        let wrapped = SendablePixelBuffer(value: pixelBuffer)
        probeQueue.async { [weak self] in
            self?.runProbe(pixelBuffer: wrapped.value)
        }
    }

    public nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        downstream?.cameraCapture(capture, didChangeState: state)
    }

    // MARK: - Internal (testing)

    /// Directly fire the stats callback with caller-supplied values.
    ///
    /// For unit tests only — bypasses Vision and AVFoundation.
    func fireStatsForTesting(
        bodyPoseMs: Double,
        handPoseMs: Double,
        faceMeshMs: Double,
        combinedMs: Double,
        frameCount: Int
    ) {
        onProbeStats(LandmarkProbeStats(
            bodyPoseMs: bodyPoseMs,
            handPoseMs: handPoseMs,
            faceMeshMs: faceMeshMs,
            combinedMs: combinedMs,
            frameCount: frameCount
        ))
    }

    // MARK: - Private: Vision execution

    private func runProbe(pixelBuffer: CVPixelBuffer) {
        let combinedToken = combinedTimer.start()

        // --- Body pose ---
        let bodyToken = bodyPoseTimer.start()
        runBodyPose(pixelBuffer: pixelBuffer)
        let bodyEnd = ContinuousClock.now
        let handToken = handPoseTimer.start()
        runHandPose(pixelBuffer: pixelBuffer)
        let handEnd = ContinuousClock.now
        let faceToken = faceMeshTimer.start()
        runFaceMesh(pixelBuffer: pixelBuffer)
        let faceEnd = ContinuousClock.now
        let combinedEnd = faceEnd   // wall-clock end of all three

        let count = frameCountLock.withLock { count -> Int in
            count += 1
            return count
        }

        Task { [weak self] in
            guard let self else { return }
            await bodyPoseTimer.stop(token: bodyToken, endInstant: bodyEnd)
            await handPoseTimer.stop(token: handToken, endInstant: handEnd)
            await faceMeshTimer.stop(token: faceToken, endInstant: faceEnd)
            await combinedTimer.stop(token: combinedToken, endInstant: combinedEnd)

            async let bodyStats     = bodyPoseTimer.statistics
            async let handStats     = handPoseTimer.statistics
            async let faceStats     = faceMeshTimer.statistics
            async let combinedStats = combinedTimer.statistics

            let (b, h, f, c) = await (bodyStats, handStats, faceStats, combinedStats)

            onProbeStats(LandmarkProbeStats(
                bodyPoseMs: b.meanMs,
                handPoseMs: h.meanMs,
                faceMeshMs: f.meanMs,
                combinedMs: c.meanMs,
                frameCount: count
            ))
        }
    }

    private func runBodyPose(pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: ProbeConstants.orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            logger.debug("bodyPose error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runHandPose(pixelBuffer: CVPixelBuffer) {
        let request = VNDetectHumanHandPoseRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: ProbeConstants.orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            logger.debug("handPose error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runFaceMesh(pixelBuffer: CVPixelBuffer) {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: ProbeConstants.orientation,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            logger.debug("faceMesh error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
