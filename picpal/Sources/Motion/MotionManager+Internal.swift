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

/// Gravity continues to report physical rotation when UIKit's portrait lock is on.
/// A narrow acceptance band and a dwell time avoid rotating while framing a shot.
struct PhysicalCameraOrientationTracker {
    private var candidate: CaptureOrientation?
    private var candidateSince: TimeInterval = 0
    private var reported: CaptureOrientation?

    mutating func update(_ sample: MotionSample) -> CaptureOrientation? {
        guard sample.isHorizonValid, sample.roll.isFinite, sample.timestamp.isFinite else {
            candidate = nil
            return nil
        }
        let angle = atan2(sin(sample.roll), cos(sample.roll))
        let tolerance = Double.pi / 6
        let next: CaptureOrientation?
        if abs(angle) < tolerance { next = .portrait }
        else if abs(angle + .pi / 2) < tolerance { next = .landscapeLeft }
        else if abs(angle - .pi / 2) < tolerance { next = .landscapeRight }
        else { next = nil }
        guard let next else { candidate = nil; return nil }
        if candidate != next || sample.timestamp < candidateSince {
            candidate = next
            candidateSince = sample.timestamp
            return nil
        }
        guard sample.timestamp - candidateSince >= 0.25, reported != next else { return nil }
        reported = next
        return next
    }
}
