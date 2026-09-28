import Foundation

/// Converts a `MotionReading` into a `TiltSignal` using a configurable dead-zone
/// and hysteresis to prevent oscillation near the level boundary.
///
/// `TiltProcessor` is a pure value type — it has no side effects and holds no
/// mutable state. The caller (e.g. `TiltMonitor`) is responsible for tracking
/// the previous `isLevel` value needed for hysteresis.
///
/// ## Hysteresis behaviour
/// - When previously **level**: stays level while `|angle| ≤ deadZone + hysteresis`.
/// - When previously **tilted**: stays tilted while `|angle| ≥ deadZone − hysteresis`.
///
/// This means there is a band around the dead-zone boundary where the previous
/// state persists, preventing rapid flipping.
public struct TiltProcessor: Sendable {

    // MARK: - Named constants

    /// Forgiving coaching tolerance: small angles can be straightened afterward.
    /// With hysteresis, correction starts above 6° and stops below 4°.
    public static let defaultDeadZoneDegrees: Double = 5.0

    /// Default hysteresis margin added to / subtracted from the dead-zone, in degrees.
    public static let defaultHysteresisDegrees: Double = 1.0

    /// Conversion factor from radians to degrees.
    private static let degreesPerRadian: Double = 180.0 / .pi

    // MARK: - Configuration

    /// Half-width of the level dead-zone in degrees.
    ///
    /// Angles with `|angleDegrees| ≤ deadZoneDegrees` are nominally level
    /// (subject to hysteresis).
    public let deadZoneDegrees: Double

    /// Hysteresis margin in degrees.
    ///
    /// The effective threshold shifts by this amount depending on the previous state,
    /// preventing rapid toggling near the boundary.
    public let hysteresisDegrees: Double

    // MARK: - Init

    public init(
        deadZoneDegrees: Double = TiltProcessor.defaultDeadZoneDegrees,
        hysteresisDegrees: Double = TiltProcessor.defaultHysteresisDegrees
    ) {
        self.deadZoneDegrees = deadZoneDegrees
        self.hysteresisDegrees = hysteresisDegrees
    }

    // MARK: - Processing

    /// Compute a `TiltSignal` from a `MotionReading`.
    ///
    /// - Parameters:
    ///   - reading: The smoothed orientation reading to process.
    ///   - wasLevel: The `isLevel` value from the previous call — used to apply hysteresis.
    /// - Returns: A new `TiltSignal` reflecting the current orientation.
    public func process(reading: MotionReading, wasLevel: Bool) -> TiltSignal {
        let angleDegrees = reading.roll * Self.degreesPerRadian
        let absAngle = abs(angleDegrees)

        let isLevel: Bool
        if wasLevel {
            // Currently level: stay level until we exceed the upper threshold.
            isLevel = absAngle <= deadZoneDegrees + hysteresisDegrees
        } else {
            // Currently tilted: stay tilted until we drop below the lower threshold.
            isLevel = absAngle < deadZoneDegrees - hysteresisDegrees
        }

        return TiltSignal(angleDegrees: angleDegrees, isLevel: isLevel)
    }
}
