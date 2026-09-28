import Foundation

/// Pure, thread-safe-by-value struct that applies a low-pass filter and
/// a rolling-window settle detector to a stream of `MotionSample` values.
///
/// `MotionProcessor` has no side effects and no threading — it is a pure
/// transformation from sample to `(MotionReading, settleChanged)`. Thread safety
/// is the caller's responsibility (typically via `OSAllocatedUnfairLock`).
struct MotionProcessor {

    // MARK: - Configuration (immutable after init)

    let smoothingFactor: Double   // α in the low-pass filter, ∈ (0, 1]
    let settleThreshold: Double   // angular velocity magnitude (rad/s)
    let settleWindow: TimeInterval // seconds below threshold before declaring settled

    // MARK: - Internal state (mutated on each call to process)

    /// Low-pass filter state; `nil` until the first sample is received.
    private var smoothedRoll: Double? = nil
    private var smoothedPitch: Double? = nil

    /// Timestamp of the most recent rotation-rate spike (or first reading).
    /// `nil` until the first sample is received.
    private var lastSpikeTime: TimeInterval? = nil

    /// Current settled state.
    private(set) var isSettled: Bool = false

    // MARK: - Init

    /// Explicit initializer required because `private` stored properties suppress the
    /// synthesized memberwise init, making it inaccessible outside the struct.
    init(smoothingFactor: Double, settleThreshold: Double, settleWindow: TimeInterval) {
        self.smoothingFactor = smoothingFactor
        self.settleThreshold = settleThreshold
        self.settleWindow = settleWindow
    }

    // MARK: - Processing

    /// Process one `MotionSample` and return the resulting orientation reading
    /// together with an optional settle-state change.
    ///
    /// - Returns:
    ///   - `reading`: Smoothed `MotionReading` for the current sample.
    ///   - `settleChanged`: The new `isSettled` value when it changed, or `nil`
    ///     if the settled state is unchanged.
    mutating func process(sample: MotionSample) -> (reading: MotionReading, settleChanged: Bool?) {
        // MARK: Low-pass filter
        let newRoll: Double
        let newPitch: Double

        if let prevRoll = smoothedRoll, let prevPitch = smoothedPitch {
            newRoll  = smoothingFactor * sample.roll  + (1.0 - smoothingFactor) * prevRoll
            newPitch = smoothingFactor * sample.pitch + (1.0 - smoothingFactor) * prevPitch
        } else {
            // First reading: pass raw values through without filtering.
            newRoll  = sample.roll
            newPitch = sample.pitch
        }
        smoothedRoll  = newRoll
        smoothedPitch = newPitch

        // MARK: Settle detection
        // Initialise the spike clock to the first sample's timestamp so we require
        // a full settle window of stillness before declaring settled.
        if lastSpikeTime == nil {
            lastSpikeTime = sample.timestamp
        }

        let magnitude = (sample.rotationRateX * sample.rotationRateX
                       + sample.rotationRateY * sample.rotationRateY
                       + sample.rotationRateZ * sample.rotationRateZ).squareRoot()

        if magnitude > settleThreshold {
            lastSpikeTime = sample.timestamp
        }

        let elapsed = sample.timestamp - (lastSpikeTime ?? sample.timestamp)
        let newIsSettled = elapsed >= settleWindow

        var settleChanged: Bool? = nil
        if newIsSettled != isSettled {
            isSettled = newIsSettled
            settleChanged = newIsSettled
        }

        let reading = MotionReading(roll: newRoll, pitch: newPitch, timestamp: sample.timestamp,
                                    angularSpeed: magnitude)
        return (reading, settleChanged)
    }
}
