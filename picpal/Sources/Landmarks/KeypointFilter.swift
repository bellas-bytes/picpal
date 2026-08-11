import CoreGraphics

// MARK: - Keypoint

/// A single landmark keypoint with its detection confidence.
///
/// Immutable value type — safe to share across isolation boundaries.
public struct Keypoint: Sendable, Equatable {

    /// Position in UIKit-normalized coordinates (top-left origin, range 0–1).
    public let point: CGPoint

    /// Detection confidence in the range 0.0–1.0.
    public let confidence: Float

    public init(point: CGPoint, confidence: Float) {
        self.point = point
        self.confidence = confidence
    }
}

// MARK: - KeypointFilter

/// Pure, stateless filter that discards low-confidence keypoints.
///
/// ## Usage
/// ```swift
/// if let kp = KeypointFilter.filter(rawKeypoint) {
///     // confidence meets the floor — safe to use in geometry
/// }
/// ```
///
/// The filter is an `enum` (no instances) to make the pure-function intent
/// explicit: no state, no lock, no side effects.
public enum KeypointFilter {

    // MARK: - Constants

    /// Project-wide confidence floor applied when no custom floor is supplied.
    ///
    /// Per-signal tickets (M2-3/4/5) may pass a different `floor` value.
    public static let defaultConfidenceFloor: Float = 0.6

    // MARK: - API

    /// Returns `keypoint` if `keypoint.confidence >= floor`, otherwise `nil`.
    ///
    /// - Parameters:
    ///   - keypoint: The raw keypoint to evaluate.
    ///   - floor: Minimum acceptable confidence. Defaults to `defaultConfidenceFloor`.
    /// - Returns: The original keypoint unchanged, or `nil` when confidence is too low.
    public static func filter(
        _ keypoint: Keypoint,
        floor: Float = KeypointFilter.defaultConfidenceFloor
    ) -> Keypoint? {
        guard keypoint.confidence >= floor else { return nil }
        return keypoint
    }
}
