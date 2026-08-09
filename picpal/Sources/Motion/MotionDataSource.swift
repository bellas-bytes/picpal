import Foundation
@preconcurrency import CoreMotion

// MARK: - MotionSample

/// Raw motion values extracted from a single CoreMotion update.
///
/// All fields are value types, making `MotionSample` trivially `Sendable`.
struct MotionSample: Sendable {
    /// Device attitude roll (radians), from `CMDeviceMotion.attitude.roll`.
    let roll: Double
    /// Device attitude pitch (radians), from `CMDeviceMotion.attitude.pitch`.
    let pitch: Double
    /// Rotation rate X component (rad/s), from `CMDeviceMotion.rotationRate.x`.
    let rotationRateX: Double
    /// Rotation rate Y component (rad/s), from `CMDeviceMotion.rotationRate.y`.
    let rotationRateY: Double
    /// Rotation rate Z component (rad/s), from `CMDeviceMotion.rotationRate.z`.
    let rotationRateZ: Double
    /// CoreMotion sample timestamp (seconds since device boot).
    let timestamp: TimeInterval
}

// MARK: - MotionDataSource protocol

/// Abstraction over `CMMotionManager` that allows synthetic data injection in tests.
///
/// Conforming types must be safe to use from any thread (`@unchecked Sendable`
/// or `Sendable`). The real implementation wraps `CMMotionManager`; test
/// implementations feed synthetic `MotionSample` values directly.
protocol MotionDataSource: AnyObject {
    /// Whether device motion data is available on this hardware.
    var isDeviceMotionAvailable: Bool { get }

    /// Begin delivering `MotionSample` values to `handler` on `queue`.
    ///
    /// - Parameters:
    ///   - queue: The `OperationQueue` on which `handler` is invoked.
    ///   - updateInterval: The desired sample interval (seconds).
    ///   - handler: Receives each `MotionSample`, or `nil` + an error on failure.
    func startUpdates(
        to queue: OperationQueue,
        updateInterval: TimeInterval,
        handler: @escaping @Sendable (MotionSample?, Error?) -> Void
    )

    /// Stop device motion updates.
    func stopUpdates()
}

// MARK: - CoreMotionDataSource

/// Production `MotionDataSource` backed by a real `CMMotionManager`.
///
/// `CMMotionManager` handles internal synchronisation; `@unchecked Sendable`
/// is safe because the start/stop API is called from `MotionManager`'s
/// dedicated queue, and the update callback is delivered on the provided queue.
final class CoreMotionDataSource: MotionDataSource, @unchecked Sendable {

    private let manager = CMMotionManager()

    var isDeviceMotionAvailable: Bool { manager.isDeviceMotionAvailable }

    func startUpdates(
        to queue: OperationQueue,
        updateInterval: TimeInterval,
        handler: @escaping @Sendable (MotionSample?, Error?) -> Void
    ) {
        manager.deviceMotionUpdateInterval = updateInterval
        manager.startDeviceMotionUpdates(to: queue) { motion, error in
            guard let motion else {
                handler(nil, error)
                return
            }
            let sample = MotionSample(
                roll: motion.attitude.roll,
                pitch: motion.attitude.pitch,
                rotationRateX: motion.rotationRate.x,
                rotationRateY: motion.rotationRate.y,
                rotationRateZ: motion.rotationRate.z,
                timestamp: motion.timestamp
            )
            handler(sample, nil)
        }
    }

    func stopUpdates() {
        manager.stopDeviceMotionUpdates()
    }
}
