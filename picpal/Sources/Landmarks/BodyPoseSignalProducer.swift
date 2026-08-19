import Vision

// MARK: - BodyPoseSignalProducer

/// Wraps `BodyPoseAnalyzer` with a `TemporalSmoother` and exposes a simple
/// one-observation-per-tick interface for the M2-6 cadence pipeline.
///
/// ## Contract
/// - A stable `BodySignal` (appearing in `stableFrameCount` consecutive ticks)
///   triggers `onSignal` exactly once (edge-triggered).
/// - When the stable value changes or a `nil` observation is received and stability
///   was previously confirmed, `onSignal(.noPersonPresent)` fires exactly once.
/// - `onSignal` is invoked on the calling thread; no internal dispatch.
///
/// ## Threading
/// All stored properties are immutable reference types that manage their own
/// thread safety. `BodyPoseSignalProducer` is `@unchecked Sendable` to satisfy
/// the `Sendable` requirements of pipeline components that hold it.
public final class BodyPoseSignalProducer: @unchecked Sendable {

    // MARK: - State

    private let analyzer: BodyPoseAnalyzer
    private let smoother: TemporalSmoother<BodySignal>

    // MARK: - Init

    /// Creates a `BodyPoseSignalProducer`.
    ///
    /// - Parameters:
    ///   - analyzer: Geometry engine. Defaults to a `BodyPoseAnalyzer` with default constants.
    ///   - stableFrameCount: Consecutive equal frames required before `onSignal` fires.
    ///   - onSignal: Called (on the calling thread) when a stable `BodySignal` is
    ///     confirmed or stability is broken. Receives `BodySignal.noPersonPresent`
    ///     when the smoother's stability is broken by a `nil` observation.
    public init(
        analyzer: BodyPoseAnalyzer = BodyPoseAnalyzer(),
        stableFrameCount: Int = TemporalSmoother<BodySignal>.defaultStableFrameCount,
        onSignal: @escaping @Sendable (BodySignal) -> Void
    ) {
        self.analyzer = analyzer
        // Capture the onSignal parameter (not self) to avoid requiring a
        // two-phase init. The smoother maps nil → .noPersonPresent before calling out.
        self.smoother = TemporalSmoother<BodySignal>(
            stableFrameCount: stableFrameCount
        ) { [onSignal] signal in
            onSignal(signal ?? .noPersonPresent)
        }
    }

    // MARK: - Public API

    /// Feed one body-pose observation per cadence tick.
    ///
    /// Pass `nil` when the cadence controller reports no person present — this
    /// propagates directly to the underlying smoother as a nil update.
    ///
    /// - Parameter observation: The latest body-pose result, or `nil`.
    public func process(observation: VNHumanBodyPoseObservation?) {
        guard let observation else {
            smoother.update(nil)
            return
        }
        let signal = analyzer.analyze(observation: observation)
        smoother.update(signal)
    }

    // MARK: - Internal (exposed for unit tests)

    /// Directly injects a signal into the smoother, bypassing Vision observation.
    ///
    /// For unit tests only — lets tests exercise the smoother's stability-change
    /// behaviour without constructing a `VNHumanBodyPoseObservation`.
    func injectSignalForTesting(_ signal: BodySignal?) {
        smoother.update(signal)
    }
}
