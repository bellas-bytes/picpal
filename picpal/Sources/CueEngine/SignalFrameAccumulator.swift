import Foundation
import os

/// Thread-safe accumulator that collects individual signals and calls the cue engine
/// whenever any signal is updated.
///
/// Each monitor fires its `onSignal` callback independently on its own queue.
/// `SignalFrameAccumulator` merges those signals into a complete `SignalFrame`
/// snapshot and passes it to `onFrame` after every update.
///
/// ## Thread safety
/// `update` methods may be called from any thread. All reads and writes to the
/// accumulated `SignalFrame` are protected by `OSAllocatedUnfairLock`.
///
/// ## Usage
/// ```swift
/// let accumulator = SignalFrameAccumulator { frame in
///     let cue = engine.process(frame: frame)
///     // dispatch cue to @MainActor
/// }
/// tiltMonitor.onSignal = { accumulator.update(tilt: $0) }
/// ```
public final class SignalFrameAccumulator: @unchecked Sendable {

    // MARK: - State

    private let lock: OSAllocatedUnfairLock<SignalFrame>
    private let onFrame: @Sendable (SignalFrame) -> Void

    // MARK: - Init

    /// Creates a `SignalFrameAccumulator`.
    ///
    /// - Parameter onFrame: Called on the calling thread after every signal update
    ///   with the latest merged `SignalFrame`. Process cues and dispatch UI updates
    ///   inside this closure.
    public init(onFrame: @escaping @Sendable (SignalFrame) -> Void) {
        lock = OSAllocatedUnfairLock(initialState: .empty)
        self.onFrame = onFrame
    }

    // MARK: - Update methods

    /// Merges a new `TiltSignal` into the accumulated frame and fires `onFrame`.
    public func update(tilt: TiltSignal) {
        let frame = lock.withLock { current in
            let updated = SignalFrame(
                timestamp: Date().timeIntervalSince1970,
                tilt: tilt,
                blur: current.blur,
                exposure: current.exposure,
                framing: current.framing
            )
            current = updated
            return updated
        }
        onFrame(frame)
    }

    /// Merges a new `BlurSignal` into the accumulated frame and fires `onFrame`.
    public func update(blur: BlurSignal) {
        let frame = lock.withLock { current in
            let updated = SignalFrame(
                timestamp: Date().timeIntervalSince1970,
                tilt: current.tilt,
                blur: blur,
                exposure: current.exposure,
                framing: current.framing
            )
            current = updated
            return updated
        }
        onFrame(frame)
    }

    /// Merges a new `ExposureSignal` into the accumulated frame and fires `onFrame`.
    public func update(exposure: ExposureSignal) {
        let frame = lock.withLock { current in
            let updated = SignalFrame(
                timestamp: Date().timeIntervalSince1970,
                tilt: current.tilt,
                blur: current.blur,
                exposure: exposure,
                framing: current.framing
            )
            current = updated
            return updated
        }
        onFrame(frame)
    }

    /// Merges a new `FramingSignal` into the accumulated frame and fires `onFrame`.
    public func update(framing: FramingSignal) {
        let frame = lock.withLock { current in
            let updated = SignalFrame(
                timestamp: Date().timeIntervalSince1970,
                tilt: current.tilt,
                blur: current.blur,
                exposure: current.exposure,
                framing: framing
            )
            current = updated
            return updated
        }
        onFrame(frame)
    }
}
