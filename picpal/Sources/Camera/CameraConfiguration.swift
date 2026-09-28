import AVFoundation
import UIKit

/// Immutable snapshot of capture settings passed to `CameraCapture`.
///
/// The initialiser clamps `targetFPS` to the supported range so callers
/// never need to guard against out-of-range values.
public struct CameraConfiguration: Sendable, Equatable {

    // MARK: - Constants

    /// Lowest frame rate the capture pipeline will accept.
    public static let minimumFPS: Int = 1
    /// Highest frame rate the capture pipeline will accept.
    public static let maximumFPS: Int = 60

    // MARK: - Properties

    /// AVFoundation session preset that controls output resolution.
    public let preset: AVCaptureSession.Preset
    /// Requested frames per second, clamped to `[minimumFPS, maximumFPS]`.
    public let targetFPS: Int

    // MARK: - Init

    /// Create a configuration.
    /// - Parameters:
    ///   - preset: Session preset controlling resolution.
    ///   - targetFPS: Desired frame rate; automatically clamped to the valid range.
    public init(preset: AVCaptureSession.Preset, targetFPS: Int) {
        self.preset = preset
        self.targetFPS = min(Self.maximumFPS, max(Self.minimumFPS, targetFPS))
    }

    // MARK: - Defaults

    /// 720 p at 30 fps — a good balance of quality and CPU headroom for on-device analysis.
    public static let defaultConfiguration = CameraConfiguration(
        preset: .hd1280x720,
        targetFPS: 30
    )
}

/// Device orientation shared by preview, analysis buffers, photo output and horizon coaching.
public enum CaptureOrientation: Sendable, Equatable {
    case portrait, landscapeLeft, landscapeRight

    public var previewAspectRatio: Double { self == .portrait ? 3.0 / 4.0 : 4.0 / 3.0 }

    public var videoOrientation: AVCaptureVideoOrientation {
        switch self {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        }
    }

    public func updated(for device: UIDeviceOrientation) -> Self {
        switch device {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: self
        }
    }

    public func updated(forInterface orientation: UIInterfaceOrientation) -> Self {
        switch orientation {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: self
        }
    }

    public func relativeRoll(_ roll: Double) -> Double {
        guard self != .portrait else { return roll }
        let baseline: Double = switch self {
        case .portrait: 0
        case .landscapeLeft: -.pi / 2
        case .landscapeRight: .pi / 2
        }
        return atan2(sin(roll - baseline), cos(roll - baseline))
    }
}

enum SelfieFramingAdvice {
    static func caption(direction: String?, zoom: CGFloat, minimumZoom: CGFloat) -> String? {
        switch direction {
        case "move_back": zoom > minimumZoom + 0.02
            ? "Zoom out to match the selfie framing"
            : "Widest selfie view — match your head and hand pose"
        case "move_closer": "Zoom in slightly or bring the phone closer"
        default: nil
        }
    }
}
