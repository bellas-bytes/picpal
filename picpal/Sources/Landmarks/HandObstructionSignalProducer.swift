// MARK: - HandObstructionSignalProducer

/// Wraps `HandObstructionAnalyzer` with a `TemporalSmoother` and exposes a simple
/// one-frame-per-cadence-tick interface for the M2-6 pipeline.
///
/// ## Contract
/// - A stable `BodySignal` (appearing in `stableFrameCount` consecutive ticks)
///   triggers `onSignal` exactly once (edge-triggered).
/// - When the stable value changes, or an empty keypoint list is received after
///   stability was confirmed, `onSignal(.noPersonPresent)` fires exactly once.
/// - `onSignal` is invoked on the calling thread; no internal dispatch.
///
/// ## Multi-hand usage
/// Concatenate all detected hands' keypoints into a single array before calling
/// `process(keypoints:)`. The analyzer treats the lens as obstructed if *any*
/// hand covers it.
///
/// ## Threading
/// All stored properties are immutable reference types that manage their own
/// thread safety. `HandObstructionSignalProducer` is `@unchecked Sendable` to
/// satisfy the `Sendable` requirements of pipeline components that hold it.
public final class HandObstructionSignalProducer: @unchecked Sendable {

    // MARK: - State

    private let analyzer: HandObstructionAnalyzer
    private let smoother: TemporalSmoother<BodySignal>

    // MARK: - Init

    /// Creates a `HandObstructionSignalProducer`.
    ///
    /// - Parameters:
    ///   - analyzer: Geometry engine. Defaults to `HandObstructionAnalyzer`
    ///     with its default constants.
    ///   - stableFrameCount: Consecutive equal frames required before `onSignal`
    ///     fires. Defaults to `TemporalSmoother.defaultStableFrameCount`.
    ///   - onSignal: Called on the calling thread when a stable `BodySignal` is
    ///     confirmed or stability is broken. Receives `BodySignal.noPersonPresent`
    ///     when stability is broken by a nil (empty keypoints) update.
    public init(
        analyzer: HandObstructionAnalyzer = HandObstructionAnalyzer(),
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

    /// Feed one frame's hand keypoints per cadence tick.
    ///
    /// Pass an empty array when no hand is detected — this propagates directly
    /// to the underlying smoother as a nil update.
    ///
    /// - Parameter keypoints: The current frame's hand keypoints (all hands
    ///   concatenated), or empty when no hand is present.
    public func process(keypoints: [Keypoint]) {
        guard !keypoints.isEmpty else {
            smoother.update(nil)
            return
        }
        let signal = analyzer.analyze(keypoints: keypoints)
        smoother.update(signal)
    }
}
