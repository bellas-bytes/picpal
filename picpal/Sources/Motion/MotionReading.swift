import Foundation

/// An immutable snapshot of smoothed device orientation delivered by `MotionManager`.
///
/// Roll and pitch are expressed in radians after a low-pass filter has been applied
/// to reduce sensor jitter. `timestamp` is the raw CoreMotion sample timestamp.
public struct MotionReading: Sendable {
    /// Rotation around the device's longitudinal axis (radians).
    public let roll: Double
    /// Rotation around the device's lateral axis (radians).
    public let pitch: Double
    /// CoreMotion sample timestamp (seconds since device boot).
    public let timestamp: TimeInterval
}
