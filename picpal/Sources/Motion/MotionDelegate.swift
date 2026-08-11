/// Receives orientation and stability events from a `MotionManager` instance.
///
/// ## Threading
/// Both methods are always called on the **main queue**. Implementations must not
/// block the main queue for extended periods.
public protocol MotionDelegate: AnyObject {

    /// Delivers a smoothed orientation reading at the configured update rate.
    ///
    /// - Parameters:
    ///   - manager: The `MotionManager` producing the reading.
    ///   - reading: The current low-pass filtered roll/pitch orientation.
    nonisolated func motionManager(_ manager: MotionManager, didUpdate reading: MotionReading)

    /// Reports a change in the device's motion-settled state.
    ///
    /// Called only when the value actually changes — not on every update.
    ///
    /// - Parameters:
    ///   - manager: The `MotionManager` emitting the event.
    ///   - isSettled: `true` when motion has been below the threshold for the full settle
    ///     window; `false` immediately after any spike above the threshold.
    nonisolated func motionManager(_ manager: MotionManager, didChangeSettled isSettled: Bool)
}
