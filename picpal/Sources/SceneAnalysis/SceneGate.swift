import CoreVideo
import os

// MARK: - Private state

private struct GateState {
    var isSettled: Bool
    var lastSignature: SceneSignature?
}

// MARK: - SceneGate

/// Combines the settle gate and scene-change gate into a single forwarding decision.
///
/// Thread-safe: `update(isSettled:)` and `shouldProcess(pixelBuffer:)` may be called
/// from different threads.
public final class SceneGate: @unchecked Sendable {

    public static let defaultSettleRequired: Bool = true

    private let lock: OSAllocatedUnfairLock<GateState>
    private let settleRequired: Bool

    public init(settleRequired: Bool = SceneGate.defaultSettleRequired) {
        self.settleRequired = settleRequired
        self.lock = OSAllocatedUnfairLock(
            initialState: GateState(isSettled: false, lastSignature: nil)
        )
    }

    // MARK: - Public interface

    /// Called from MotionManager delegate on main queue — updates the settle flag.
    public func update(isSettled: Bool) {
        lock.withLock { $0.isSettled = isSettled }
    }

    /// Called from camera queue — returns `true` if the frame should be processed.
    ///
    /// Side-effect: when returning `true`, stores the frame's signature as the
    /// new baseline for subsequent comparisons.
    public func shouldProcess(pixelBuffer: CVPixelBuffer) -> Bool {
        // Step 1: Check settle gate (read isSettled from lock)
        let isSettled = lock.withLock { $0.isSettled }
        if settleRequired && !isSettled { return false }

        // Step 2: Compute signature outside the lock (may be slow)
        guard let signature = SceneSignature.compute(from: pixelBuffer) else {
            return true  // Can't compute — pass through
        }

        // Steps 3–5: Compare against last signature and update atomically
        return lock.withLock { state in
            guard let lastSig = state.lastSignature else {
                // Step 3: First frame — store and pass through
                state.lastSignature = signature
                return true
            }
            // Step 4: Material change — update and pass through
            if signature.isMateriallyDifferent(from: lastSig) {
                state.lastSignature = signature
                return true
            }
            // Step 5: No material change — drop frame
            return false
        }
    }

    /// Returns the signature of the most recently processed frame, or `nil` if no frame
    /// has been processed yet. Used by M3 for VLM stale-suppression.
    public var lastProcessedSignature: SceneSignature? {
        lock.withLock { $0.lastSignature }
    }
}
