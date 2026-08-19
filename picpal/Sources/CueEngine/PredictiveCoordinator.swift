import Foundation

// MARK: - PredictiveCoordinator

/// Wires SignalTrendDetector and PredictiveCoach into one per-frame call.
/// Called from the SignalFrameAccumulator callback before engine.process.
final class PredictiveCoordinator: @unchecked Sendable {

    private let detector: SignalTrendDetector
    private let tiltCoach: PredictiveCoach
    private let exposureCoach: PredictiveCoach

    init(
        waitWindowSeconds: Double = PredictiveCoach.defaultWaitWindowSeconds,
        improvementSlopeThreshold: Double = SignalTrendDetector.defaultImprovementSlopeThreshold
    ) {
        detector = SignalTrendDetector(improvementSlopeThreshold: improvementSlopeThreshold)
        tiltCoach = PredictiveCoach(waitWindowSeconds: waitWindowSeconds)
        exposureCoach = PredictiveCoach(waitWindowSeconds: waitWindowSeconds)
    }

    /// Testability initialiser — allows injecting pre-configured detector and coaches.
    init(
        detector: SignalTrendDetector,
        tiltCoach: PredictiveCoach,
        exposureCoach: PredictiveCoach
    ) {
        self.detector = detector
        self.tiltCoach = tiltCoach
        self.exposureCoach = exposureCoach
    }

    // MARK: - Factory

    /// Creates the coordinator with tuning values applied in DEBUG builds.
    static func live() -> PredictiveCoordinator {
        #if DEBUG
        return PredictiveCoordinator(
            waitWindowSeconds: TuningSettings.shared.predictiveWaitWindowSeconds,
            improvementSlopeThreshold: TuningSettings.shared.trendImprovementSlope
        )
        #else
        return PredictiveCoordinator()
        #endif
    }

    // MARK: - Update

    /// Records current signal values, queries trends, and returns coach actions for this frame.
    func update(_ frame: SignalFrame) -> PredictiveActions {
        // Record tilt: track absolute angle. Decreasing angle = improving toward level.
        if let tilt = frame.tilt {
            detector.record(signal: .tilt, value: abs(tilt.angleDegrees))
        }

        // Record exposure clipping only when not OK — decreasing fraction = improving.
        if let exposure = frame.exposure, exposure.level != .ok {
            let clipping = max(exposure.shadowClipFraction, exposure.highlightClipFraction)
            detector.record(signal: .exposure, value: clipping)
        }

        let isLevelTilt = frame.tilt?.isLevel ?? true
        let isOkExposure = (frame.exposure?.level ?? .ok) == .ok

        return PredictiveActions(
            tilt: tiltCoach.update(
                trend: detector.trend(for: .tilt),
                isWithinThreshold: isLevelTilt
            ),
            exposure: exposureCoach.update(
                trend: detector.trend(for: .exposure),
                isWithinThreshold: isOkExposure
            )
        )
    }

    // MARK: - Reset

    /// Clears all trend data and resets both coaches. Call on scene change or background transition.
    func reset() {
        detector.reset()
        tiltCoach.reset()
        exposureCoach.reset()
    }
}
