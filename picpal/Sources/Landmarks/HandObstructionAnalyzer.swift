import CoreGraphics

// MARK: - HandObstructionAnalyzer

/// Pure geometry analyzer that processes MediaPipe hand keypoints and determines
/// whether a hand or finger cluster is obstructing the camera lens edge.
///
/// ## Algorithm
/// The lens is "obstructed" when at least `minObstructingKeypoints` qualified
/// keypoints (those meeting `keypointConfidenceFloor`) each lie within
/// `edgeMargin` of any frame edge. This conservative threshold prevents
/// isolated stray-finger pixels from triggering the signal.
///
/// ## Threading
/// All stored properties are immutable after initialisation — no lock is needed.
/// `HandObstructionAnalyzer` is declared `@unchecked Sendable` so it can be stored
/// and shared by pipeline components that are themselves `@unchecked Sendable`.
///
/// ## Testing
/// Call `analyzeKeypoints(_:)` directly with synthetic `[Keypoint]` arrays to
/// exercise geometry logic without MediaPipe framework types.
public final class HandObstructionAnalyzer: @unchecked Sendable {

    // MARK: - Constants

    /// MediaPipe hand keypoint confidence floor.
    public static let defaultKeypointConfidenceFloor: Float = 0.6

    /// Fraction of frame edge within which a keypoint counts as "near edge".
    public static let defaultEdgeMargin: Double = 0.15

    /// Minimum number of keypoints near an edge to classify as obstruction.
    public static let defaultMinObstructingKeypoints: Int = 3

    // MARK: - Configuration (immutable)

    private let keypointConfidenceFloor: Float
    private let edgeMargin: Double
    private let minObstructingKeypoints: Int

    // MARK: - Init

    public init(
        keypointConfidenceFloor: Float = HandObstructionAnalyzer.defaultKeypointConfidenceFloor,
        edgeMargin: Double = HandObstructionAnalyzer.defaultEdgeMargin,
        minObstructingKeypoints: Int = HandObstructionAnalyzer.defaultMinObstructingKeypoints
    ) {
        self.keypointConfidenceFloor = keypointConfidenceFloor
        self.edgeMargin = edgeMargin
        self.minObstructingKeypoints = minObstructingKeypoints
    }

    // MARK: - Public API

    /// Analyse hand keypoints and return a `BodySignal`.
    ///
    /// MediaPipe landmarks are converted to UIKit-normalised coordinates before
    /// any geometry. For multi-hand frames, concatenate all hands' keypoints and
    /// call once — obstruction fires if *any* hand covers the lens.
    ///
    /// - Parameter keypoints: Raw MediaPipe hand keypoints (21 per hand, any count).
    /// - Returns: A `BodySignal`, or `nil` when fewer than `minObstructingKeypoints`
    ///   pass `keypointConfidenceFloor`.
    public func analyze(keypoints: [Keypoint]) -> BodySignal? {
        // Convert all keypoints from MediaPipe → UIKit coordinates before geometry.
        // MediaPipe and UIKit share top-left origin; mediapipePointToUIKit is a
        // validated pass-through that documents the coordinate convention explicitly.
        let converted = keypoints.map { kp in
            Keypoint(
                point: LandmarkCoordinates.mediapipePointToUIKit(kp.point),
                confidence: kp.confidence
            )
        }
        return analyzeKeypoints(converted)
    }

    // MARK: - Internal (exposed for unit tests)

    /// Geometry-only entry point that accepts pre-converted UIKit keypoints.
    ///
    /// Declared `internal` (not `private`) so unit tests can call it directly
    /// with synthetic `Keypoint` values, bypassing MediaPipe type construction.
    ///
    /// - Parameter keypoints: Keypoints already in UIKit-normalised coordinates
    ///   (top-left origin, 0–1 range on both axes).
    /// - Returns: A `BodySignal`, or `nil` when fewer than `minObstructingKeypoints`
    ///   pass `keypointConfidenceFloor`.
    func analyzeKeypoints(_ keypoints: [Keypoint]) -> BodySignal? {
        // Filter to keypoints that meet the confidence floor.
        let qualifiedKeypoints = keypoints.compactMap { kp in
            KeypointFilter.filter(kp, floor: keypointConfidenceFloor)
        }

        // Guard: need at least minObstructingKeypoints qualified keypoints.
        guard qualifiedKeypoints.count >= minObstructingKeypoints else {
            return nil
        }

        // Find qualified keypoints that are near any frame edge.
        let obstructingKeypoints = qualifiedKeypoints.filter { kp in
            isNearEdge(point: kp.point)
        }

        guard obstructingKeypoints.count >= minObstructingKeypoints else {
            return BodySignal(hint: .goodBody, confidence: 1.0, dominantRect: nil)
        }

        // Confidence is the mean over obstructing keypoints.
        let totalConfidence = obstructingKeypoints
            .map { Double($0.confidence) }
            .reduce(0, +)
        let meanConfidence = Float(totalConfidence / Double(obstructingKeypoints.count))

        return BodySignal(hint: .lensObstructed, confidence: meanConfidence, dominantRect: nil)
    }

    // MARK: - Private helpers

    /// Returns `true` when `point` lies within `edgeMargin` of any frame edge.
    ///
    /// Geometry operates on UIKit-normalised coordinates (0–1 range, top-left
    /// origin). The normalised maximum is implicitly 1.0 on both axes.
    private func isNearEdge(point: CGPoint) -> Bool {
        let margin = edgeMargin
        return point.x < margin
            || point.x > 1.0 - margin
            || point.y < margin
            || point.y > 1.0 - margin
    }
}
