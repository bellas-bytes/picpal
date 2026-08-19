/// An immutable snapshot of per-model and combined MediaPipe landmark latency.
///
/// Produced by `MediaPipeLandmarkProbe` after each processed camera frame.
/// Mirrors the structure of `LandmarkProbeStats` (Vision baseline) to enable
/// direct comparison in the M2-0 latency report.
public struct MediaPipeProbeStats: Sendable, Equatable {

    // MARK: - Per-model mean latencies

    /// Rolling mean inference time for `HandLandmarker` (ms).
    public let handPoseMs: Double

    /// Rolling mean inference time for `FaceLandmarker` (ms).
    public let faceMeshMs: Double

    /// Rolling mean wall-clock time for both landmarkers run sequentially (ms).
    public let combinedMs: Double

    /// Total number of frames processed so far.
    public let frameCount: Int

    // MARK: - M0-5 Vision baselines (for comparison)

    /// Vision Hand p95 baseline from M0-5 (iPhone 17, thermal nominal).
    public static let visionHandBaselineP95Ms: Double = 84.1

    /// Vision Face p95 baseline from M0-5.
    public static let visionFaceBaselineP95Ms: Double = 24.3

    /// Vision combined (Body + Hand + Face) p95 from M0-5.
    public static let visionCombinedBaselineP95Ms: Double = 140.7

    // MARK: - Decision thresholds

    /// Combined p95 below this value → PROCEED with hybrid stack.
    public static let proceedThresholdMs: Double = 150.0

    /// Combined p95 below this value → FALLBACK A (drop MediaPipe face).
    public static let fallbackAThresholdMs: Double = 200.0

    // MARK: - Baseline

    /// Zero-value baseline used before any frames have been processed.
    public static let zero = MediaPipeProbeStats(
        handPoseMs: 0,
        faceMeshMs: 0,
        combinedMs: 0,
        frameCount: 0
    )
}
