import Foundation

/// Allows normal small framing changes; rejects fast rotation without a dwell timer.
struct CaptureMotionTolerance {
    private var previous: MotionReading?

    mutating func update(_ reading: MotionReading) -> Bool {
        guard reading.roll.isFinite, reading.pitch.isFinite, reading.timestamp.isFinite else {
            previous = nil
            return false
        }
        defer { previous = reading }
        guard let previous else { return false }
        let elapsed = reading.timestamp - previous.timestamp
        guard elapsed > 0, elapsed <= 0.5 else { return false }
        guard let speed = reading.angularSpeed, speed.isFinite, speed >= 0 else { return false }
        return speed < 0.7
    }
}
