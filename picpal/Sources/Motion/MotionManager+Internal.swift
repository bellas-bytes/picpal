import Foundation

// Internal helpers extracted from MotionManager.swift.
// Kept separate to mirror the structure of CameraCapture+Internal.swift.

// MARK: - Thread-safe delegate wrapper

/// Thread-safe wrapper for the weak `MotionDelegate` reference.
///
/// Uses `NSLock` to protect the weak reference so it can be read and written
/// safely from any thread (the background motion queue and the main queue).
final class MotionDelegateBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var value: (any MotionDelegate)?

    func get() -> (any MotionDelegate)? {
        lock.withLock { value }
    }

    func set(_ delegate: (any MotionDelegate)?) {
        lock.withLock { value = delegate }
    }
}
