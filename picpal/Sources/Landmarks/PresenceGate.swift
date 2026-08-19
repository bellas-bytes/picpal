import CoreVideo
import os
import Vision

// MARK: - PresenceResult

/// Outcome of a single `VNDetectHumanRectanglesRequest` pass.
public struct PresenceResult: Sendable {
    /// True when at least one human detection passes the confidence threshold.
    public let personPresent: Bool
    /// Dominant subject rect in Vision normalized coordinates (bottom-left origin).
    /// Nil when `personPresent` is false.
    public let dominantRect: CGRect?

    /// Convenience sentinel used when no person is detected.
    public static let absent = PresenceResult(personPresent: false, dominantRect: nil)
}

// MARK: - PresenceGate

/// Runs `VNDetectHumanRectanglesRequest` synchronously on a pixel buffer and
/// returns a presence decision plus the dominant subject's bounding rect.
///
/// ## Thread safety
/// `PresenceGate` is stateless after initialization; `check` may be called
/// concurrently from any thread without additional synchronization.
public final class PresenceGate: @unchecked Sendable {

    // MARK: - Constants

    /// Detections below this confidence are discarded.
    public static let defaultConfidenceThreshold: Float = 0.5

    private enum GateConstants {
        /// Orientation forwarded to `VNImageRequestHandler`. The camera outputs
        /// upright buffers in the pipeline, so `.up` is correct here.
        static let orientation: CGImagePropertyOrientation = .up
    }

    // MARK: - Configuration

    private let confidenceThreshold: Float
    private let logger = Logger(subsystem: "com.picpal", category: "PresenceGate")

    // MARK: - Init

    /// Creates a `PresenceGate`.
    ///
    /// - Parameter confidenceThreshold: Minimum `VNHumanObservation.confidence`
    ///   required for a detection to count. Defaults to `defaultConfidenceThreshold`.
    public init(confidenceThreshold: Float = PresenceGate.defaultConfidenceThreshold) {
        self.confidenceThreshold = confidenceThreshold
    }

    // MARK: - Public API

    /// Synchronously runs `VNDetectHumanRectanglesRequest` on `pixelBuffer`.
    ///
    /// Dominant subject selection:
    /// - Primary key: highest `confidence` (higher wins).
    /// - Tie-break: largest bounding-box area (larger wins).
    ///
    /// - Parameter pixelBuffer: The frame to inspect.
    /// - Returns: A `PresenceResult` indicating whether a person was found and,
    ///   if so, the dominant detection's bounding rect in Vision coordinates.
    public func check(pixelBuffer: CVPixelBuffer) -> PresenceResult {
        let request = VNDetectHumanRectanglesRequest()
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: GateConstants.orientation,
            options: [:]
        )

        do {
            try handler.perform([request])
        } catch {
            logger.debug(
                "PresenceGate: Vision request failed: \(error.localizedDescription, privacy: .public)"
            )
            return .absent
        }

        let qualified = (request.results ?? []).filter { $0.confidence >= confidenceThreshold }
        guard let dominant = qualified.max(by: isLessDominant) else {
            return .absent
        }

        return PresenceResult(personPresent: true, dominantRect: dominant.boundingBox)
    }

    // MARK: - Private helpers

    /// Comparator for `max(by:)`: returns `true` when `lhs` is less dominant than `rhs`.
    ///
    /// Primary sort: confidence (higher is more dominant).
    /// Tie-break: bounding-box area (larger is more dominant).
    private func isLessDominant(
        _ lhs: VNHumanObservation,
        _ rhs: VNHumanObservation
    ) -> Bool {
        if lhs.confidence != rhs.confidence {
            return lhs.confidence < rhs.confidence
        }
        let lhsArea = lhs.boundingBox.width * lhs.boundingBox.height
        let rhsArea = rhs.boundingBox.width * rhs.boundingBox.height
        return lhsArea < rhsArea
    }
}
