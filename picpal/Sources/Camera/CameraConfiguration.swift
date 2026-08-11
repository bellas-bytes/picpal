import AVFoundation

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
