import Foundation
import os

/// Bridges `MotionDelegate` callbacks into `TiltProcessor` output, owning the
/// hysteresis state across updates.
///
/// ## Threading
/// `MotionDelegate` callbacks are always delivered on the **main queue**. The
/// `onSignal` closure is also called on the main queue. Despite this, an
/// `OSAllocatedUnfairLock` guards `lastIsLevel` for forward-compatibility with
/// any future threading changes in the motion pipeline.
///
/// ## Usage
/// ```swift
/// let monitor = TiltMonitor { signal in
///     print("Tilt: \(signal.angleDegrees)°, level: \(signal.isLevel)")
/// }
/// motionManager.delegate = monitor
/// motionManager.start()
/// ```
public final class TiltMonitor: @unchecked Sendable, MotionDelegate {

    // MARK: - Private state

    private let processor: TiltProcessor
    private let onSettleChange: (@Sendable (Bool) -> Void)?
    private let onSignal: @Sendable (TiltSignal) -> Void
    private let onReading: (@Sendable (MotionReading) -> Void)?

    /// Guards the mutable hysteresis state. Starts level (`true`).
    private let levelLock: OSAllocatedUnfairLock<Bool>

    // MARK: - Init

    /// Creates a `TiltMonitor`.
    ///
    /// - Parameters:
    ///   - processor: The `TiltProcessor` to use for each update. Defaults to `TiltProcessor()`.
    ///   - onSettleChange: Optional closure called whenever the settled state changes.
    ///     Always called on the main queue. Defaults to `nil`.
    ///   - onSignal: Closure called with each computed `TiltSignal`. Always called on the main queue.
    public init(
        processor: TiltProcessor = TiltProcessor(),
        onSettleChange: (@Sendable (Bool) -> Void)? = nil,
        onReading: (@Sendable (MotionReading) -> Void)? = nil,
        onSignal: @escaping @Sendable (TiltSignal) -> Void
    ) {
        self.processor = processor
        self.onSettleChange = onSettleChange
        self.onSignal = onSignal
        self.onReading = onReading
        self.levelLock = OSAllocatedUnfairLock(initialState: true)
    }

    // MARK: - MotionDelegate

    public nonisolated func motionManager(_ manager: MotionManager, didUpdate reading: MotionReading) {
        onReading?(reading)
        let signal = levelLock.withLock { lastIsLevel in
            let result = processor.process(reading: reading, wasLevel: lastIsLevel)
            lastIsLevel = result.isLevel
            return result
        }
        onSignal(signal)
    }

    public nonisolated func motionManager(_ manager: MotionManager, didChangeSettled isSettled: Bool) {
        onSettleChange?(isSettled)
    }
}
