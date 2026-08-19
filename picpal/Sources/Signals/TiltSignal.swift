import Foundation

/// The computed tilt state for a single analyzed frame.
///
/// Produced by `TiltProcessor` from a `MotionReading`. All properties
/// are immutable — callers receive a new value each update cycle.
public struct TiltSignal: Sendable, Equatable {

    /// Signed tilt angle in degrees.
    ///
    /// Positive = clockwise tilt (right side of device tilts down).
    /// Negative = counter-clockwise tilt (left side of device tilts down).
    public let angleDegrees: Double

    /// `true` when the device is within the level dead-zone (accounting for hysteresis).
    public let isLevel: Bool
}
