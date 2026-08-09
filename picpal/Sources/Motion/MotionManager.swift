import Foundation
import os

/// Manages device motion updates and produces a smoothed orientation stream
/// plus a stability signal used to gate expensive downstream analysis.
///
/// ## Usage
/// ```swift
/// let motion = MotionManager()
/// motion.delegate = self
/// motion.start()
/// ```
///
/// ## Thread-safety model
/// - CoreMotion updates arrive on a dedicated background `OperationQueue`.
/// - Processing (smoothing + settle detection) runs inside an `OSAllocatedUnfairLock`.
/// - `MotionReading` and `isSettled` change callbacks are always dispatched to the
///   **main queue** before delivery to the delegate.
///
/// `MotionManager` is `@unchecked Sendable`: all mutable state is synchronised via
/// `OSAllocatedUnfairLock`; `delegate` access is protected by `MotionDelegateBox`.
public final class MotionManager: @unchecked Sendable {

    // MARK: - Named constants (no inline literals)

    enum Constants {
        /// Angular velocity magnitude (rad/s) above which a reading counts as motion.
        static let settleThreshold: Double = 0.05
        /// Seconds below `settleThreshold` required before emitting `isSettled = true`.
        static let settleWindow: TimeInterval = 0.35
        /// CoreMotion update interval (seconds).
        static let updateInterval: TimeInterval = 1.0 / 60.0
        /// Low-pass filter coefficient α; higher values track faster but are noisier.
        static let smoothingFactor: Double = 0.3
    }

    // MARK: - Private state

    private let dataSource: any MotionDataSource
    private let motionQueue: OperationQueue
    private let processorLock: OSAllocatedUnfairLock<MotionProcessor>
    private let delegateBox = MotionDelegateBox()
    private let logger = Logger(subsystem: "com.picpal", category: "MotionManager")

    // MARK: - Public interface

    /// Receiver of orientation and stability events. Safe to assign from any thread.
    public weak var delegate: (any MotionDelegate)? {
        get { delegateBox.get() }
        set { delegateBox.set(newValue) }
    }

    /// Whether the device hardware supports motion data (forwarded from the data source).
    public var isDeviceMotionAvailable: Bool {
        dataSource.isDeviceMotionAvailable
    }

    // MARK: - Init

    /// Creates a `MotionManager` with injectable configuration — used in tests.
    ///
    /// - Parameters:
    ///   - dataSource: Motion data provider. Defaults to a real `CMMotionManager` wrapper.
    ///   - smoothingFactor: Low-pass α. Defaults to `Constants.smoothingFactor`.
    ///   - settleThreshold: Rotation rate magnitude spike threshold. Defaults to `Constants.settleThreshold`.
    ///   - settleWindow: Duration of stillness required to settle. Defaults to `Constants.settleWindow`.
    init(
        dataSource: any MotionDataSource,
        smoothingFactor: Double = Constants.smoothingFactor,
        settleThreshold: Double = Constants.settleThreshold,
        settleWindow: TimeInterval = Constants.settleWindow
    ) {
        self.dataSource = dataSource

        let queue = OperationQueue()
        queue.name = "com.picpal.motion"
        queue.qualityOfService = .userInteractive
        queue.maxConcurrentOperationCount = 1
        self.motionQueue = queue

        self.processorLock = OSAllocatedUnfairLock(
            initialState: MotionProcessor(
                smoothingFactor: smoothingFactor,
                settleThreshold: settleThreshold,
                settleWindow: settleWindow
            )
        )
    }

    /// Creates a `MotionManager` backed by the real device motion hardware.
    public convenience init() {
        self.init(dataSource: CoreMotionDataSource())
    }

    // MARK: - Lifecycle

    /// Begin receiving motion updates. Safe to call from any thread.
    ///
    /// A no-op if device motion is not available on this hardware.
    public func start() {
        guard dataSource.isDeviceMotionAvailable else {
            logger.warning("Device motion not available — MotionManager will not start.")
            return
        }
        dataSource.startUpdates(to: motionQueue, updateInterval: Constants.updateInterval) { [weak self] sample, error in
            guard let self else { return }
            if let error {
                self.logger.error("Motion update error: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let sample else { return }
            self.handle(sample: sample)
        }
    }

    /// Stop motion updates. Safe to call from any thread.
    public func stop() {
        dataSource.stopUpdates()
    }

    // MARK: - Private processing

    /// Called on `motionQueue` for every CoreMotion update.
    private func handle(sample: MotionSample) {
        let (reading, settleChanged) = processorLock.withLock { processor in
            processor.process(sample: sample)
        }

        let box = delegateBox
        let manager = self
        DispatchQueue.main.async {
            guard let del = box.get() else { return }
            del.motionManager(manager, didUpdate: reading)
            if let settled = settleChanged {
                del.motionManager(manager, didChangeSettled: settled)
            }
        }
    }
}
