// MARK: - GazeSignalProducer

/// Wraps `GazeAnalyzer` with a `TemporalSmoother` and exposes a simple
/// one-frame-per-cadence-tick interface for the M2-6 pipeline.
///
/// ## Contract
/// - A stable `BodySignal` (appearing in `stableFrameCount` consecutive ticks)
///   triggers `onSignal` exactly once (edge-triggered).
/// - When the stable value changes, or an empty landmark array is received after
///   stability was confirmed, `onSignal(.noPersonPresent)` fires exactly once.
/// - `onSignal` is invoked on the calling thread; no internal dispatch.
///
/// ## Multi-face usage
/// Pass the first face's landmarks — FaceLandmarker returns faces in descending
/// confidence order, so the dominant face is first.
///
/// ## Threading
/// All stored properties are immutable reference types that manage their own
/// thread safety. `GazeSignalProducer` is `@unchecked Sendable` to satisfy the
/// `Sendable` requirements of pipeline components that hold it.
public final class GazeSignalProducer: @unchecked Sendable {

    // MARK: - State

    private let analyzer: GazeAnalyzer
    private let smoother: TemporalSmoother<BodySignal>

    // MARK: - Init

    /// Creates a `GazeSignalProducer`.
    ///
    /// - Parameters:
    ///   - analyzer: Geometry engine. Defaults to `GazeAnalyzer` with its
    ///     default constants.
    ///   - stableFrameCount: Consecutive equal frames required before `onSignal`
    ///     fires. Defaults to `TemporalSmoother.defaultStableFrameCount`.
    ///   - onSignal: Called on the calling thread when a stable `BodySignal` is
    ///     confirmed or stability is broken. Receives `BodySignal.noPersonPresent`
    ///     when stability is broken by an empty (no-face) update.
    public init(
        analyzer: GazeAnalyzer = GazeAnalyzer(),
        stableFrameCount: Int = TemporalSmoother<BodySignal>.defaultStableFrameCount,
        onSignal: @escaping @Sendable (BodySignal) -> Void
    ) {
        self.analyzer = analyzer
        // Capture onSignal (not self) to avoid a two-phase init requirement.
        // The smoother maps nil → .noPersonPresent before calling out.
        self.smoother = TemporalSmoother<BodySignal>(
            stableFrameCount: stableFrameCount
        ) { [onSignal] signal in
            onSignal(signal ?? .noPersonPresent)
        }
    }

    // MARK: - Public API

    /// Feed one frame's face mesh keypoints per cadence tick.
    ///
    /// Pass an empty array when no face is detected — this propagates directly
    /// to the underlying smoother as a nil update, which fires `.noPersonPresent`
    /// if a stable signal was previously confirmed.
    ///
    /// - Parameter faceLandmarks: The current frame's face mesh keypoints (478 per
    ///   face for MediaPipe Face Landmarker), or empty when no face is detected.
    public func process(faceLandmarks: [Keypoint]) {
        guard !faceLandmarks.isEmpty else {
            smoother.update(nil)
            return
        }
        let signal = analyzer.analyze(faceLandmarks: faceLandmarks)
        smoother.update(signal)
    }
}
