import Foundation

/// An immutable snapshot of smoothed device orientation delivered by `MotionManager`.
///
/// Roll and pitch are expressed in radians after a low-pass filter has been applied
/// to reduce sensor jitter. `timestamp` is the raw CoreMotion sample timestamp.
public struct MotionReading: Sendable {
    /// Clockwise portrait horizon angle (radians); zero when nearly flat.
    public let roll: Double
    /// Rotation around the device's lateral axis (radians).
    public let pitch: Double
    /// CoreMotion sample timestamp (seconds since device boot).
    public let timestamp: TimeInterval
    /// Raw three-axis gyro magnitude (rad/s), including horizontal panning.
    public let angularSpeed: Double?

    public init(roll: Double, pitch: Double, timestamp: TimeInterval, angularSpeed: Double? = nil) {
        self.roll = roll
        self.pitch = pitch
        self.timestamp = timestamp
        self.angularSpeed = angularSpeed
    }
}
