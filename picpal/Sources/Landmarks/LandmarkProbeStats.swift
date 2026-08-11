/// An immutable snapshot of per-model and combined Vision landmark latency.
///
/// All timings are rolling means accumulated by `VisionLandmarkProbe`.
public struct LandmarkProbeStats: Sendable, Equatable {

    // MARK: - Per-model mean latencies

    /// Rolling mean inference time for `VNDetectHumanBodyPoseRequest` (ms).
    public let bodyPoseMs: Double

    /// Rolling mean inference time for `VNDetectHumanHandPoseRequest` (ms).
    public let handPoseMs: Double

    /// Rolling mean inference time for `VNDetectFaceLandmarksRequest` (ms).
    public let faceMeshMs: Double

    /// Rolling mean wall-clock time for all three requests run sequentially (ms).
    public let combinedMs: Double

    /// Total number of frames processed so far.
    public let frameCount: Int

    // MARK: - Baseline

    /// Zero-value baseline used before any frames have been processed.
    public static let zero = LandmarkProbeStats(
        bodyPoseMs: 0,
        handPoseMs: 0,
        faceMeshMs: 0,
        combinedMs: 0,
        frameCount: 0
    )
}
