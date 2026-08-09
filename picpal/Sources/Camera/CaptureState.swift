import Foundation

// Lifecycle state and camera error types extracted from CameraCapture.swift.
// Kept in a separate file to stay within the 300-line file limit.

extension CameraCapture {

    /// Lifecycle states of the capture session.
    public enum CaptureState: Sendable, Equatable {
        /// Session has not been started.
        case idle
        /// Permission granted; session is being built.
        case starting
        /// Session is actively delivering frames.
        case running
        /// `stop()` has been called; session is winding down.
        case stopping
        /// The user denied camera access.
        case permissionDenied
        /// Camera access is restricted by a policy (parental controls, MDM, etc.).
        case permissionRestricted
        /// A non-recoverable error occurred; the associated string contains a human-readable description.
        case error(String)

        public static func == (lhs: CaptureState, rhs: CaptureState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle),
                 (.starting, .starting),
                 (.running, .running),
                 (.stopping, .stopping),
                 (.permissionDenied, .permissionDenied),
                 (.permissionRestricted, .permissionRestricted):
                return true
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }
    }
}

// MARK: - Camera error definitions

enum CameraError: LocalizedError {
    case deviceUnavailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "No camera device is available on this hardware."
        case .cannotAddInput:    return "Cannot add camera input to the capture session."
        case .cannotAddOutput:   return "Cannot add video data output to the capture session."
        }
    }
}
