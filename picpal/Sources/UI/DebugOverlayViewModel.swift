import Foundation

/// Holds the display values shown by `DebugOverlayView`.
///
/// All properties start at placeholder values. Upstream tasks update them by
/// assigning to the published properties. Callers must always mutate on the main actor.
@MainActor
final class DebugOverlayViewModel: ObservableObject {

    // MARK: - Published debug fields

    /// Device tilt in degrees (placeholder: 0).
    @Published var tiltDegrees: Double = 0

    /// Laplacian blur score (placeholder: 0).
    @Published var blurScore: Double = 0

    /// Human-readable exposure level (placeholder: "—").
    @Published var exposureLevel: String = "—"

    /// Measured frames per second (placeholder: 0).
    @Published var framesPerSecond: Double = 0

    /// Thermal state description (placeholder: "nominal").
    @Published var thermalState: String = "nominal"
}
