import CoreGraphics

// MARK: - GazeAnalyzer

/// Pure geometry analyzer that takes a subset of MediaPipe face mesh keypoints
/// and determines head yaw to produce a gaze-direction body signal.
///
/// ## Algorithm
/// Three reference landmarks define a simplified face width and midline:
/// - Left temporal (index 234): widest left edge of the face contour
/// - Right temporal (index 454): widest right edge of the face contour
/// - Nose tip (index 4)
///
/// If the nose tip deviates from the face midline by more than
/// `yawThreshold × faceWidth`, the signal is `.gazeAway`.
///
/// ## Threading
/// All stored properties are immutable after initialisation — no lock is needed.
/// `GazeAnalyzer` is declared `@unchecked Sendable` so it can be stored and shared
/// by pipeline components that are themselves `@unchecked Sendable`.
///
/// ## Testing
/// Call `analyzeKeypoints(leftTemporal:rightTemporal:noseTip:)` directly with
/// synthetic `Keypoint` values to exercise geometry logic without MediaPipe types.
public final class GazeAnalyzer: @unchecked Sendable {

    // MARK: - Constants

    /// MediaPipe face landmark confidence floor applied when filtering keypoints.
    public static let defaultKeypointConfidenceFloor: Float = 0.5

    /// Fraction of face width the nose tip must deviate from the face midline
    /// before the signal is classified as `.gazeAway`.
    public static let defaultYawThreshold: Double = 0.15

    // MARK: - Reference landmark indices

    /// Landmark index for the nose tip (MediaPipe 478-point face mesh).
    private static let noseTipIndex: Int = 4

    /// Landmark index for the widest left edge of the face contour.
    private static let leftTemporalIndex: Int = 234

    /// Landmark index for the widest right edge of the face contour.
    /// The array must contain at least this many elements to be valid.
    private static let rightTemporalIndex: Int = 454

    // MARK: - Configuration (immutable)

    private let keypointConfidenceFloor: Float
    private let yawThreshold: Double

    // MARK: - Init

    public init(
        keypointConfidenceFloor: Float = GazeAnalyzer.defaultKeypointConfidenceFloor,
        yawThreshold: Double = GazeAnalyzer.defaultYawThreshold
    ) {
        self.keypointConfidenceFloor = keypointConfidenceFloor
        self.yawThreshold = yawThreshold
    }

    // MARK: - Public API

    /// Analyse face mesh keypoints and return a `BodySignal`.
    ///
    /// MediaPipe landmarks must be in normalised [0,1] top-left origin — identical
    /// to UIKit; `mediapipePointToUIKit` is called anyway for convention consistency
    /// and to make future coordinate changes easy to find.
    ///
    /// For multi-face frames: pass the first face's landmarks. FaceLandmarker
    /// returns faces in descending confidence order, so the dominant face is first.
    ///
    /// - Parameter faceLandmarks: All 478 MediaPipe face mesh keypoints indexed by
    ///   landmark ID. Must contain at least 455 elements to safely access index 454.
    /// - Returns: A `BodySignal`, or `nil` when the array is too short or any
    ///   reference landmark fails the confidence floor.
    public func analyze(faceLandmarks: [Keypoint]) -> BodySignal? {
        // Guard: array must contain all reference landmark indices (highest = 454).
        guard faceLandmarks.count > GazeAnalyzer.rightTemporalIndex else {
            return nil
        }

        // Convert MediaPipe → UIKit coordinates before any geometry.
        // MediaPipe and UIKit share top-left origin, so this is a validated
        // pass-through — called explicitly to document the coordinate source.
        let leftTemporal = Keypoint(
            point: LandmarkCoordinates.mediapipePointToUIKit(
                faceLandmarks[GazeAnalyzer.leftTemporalIndex].point
            ),
            confidence: faceLandmarks[GazeAnalyzer.leftTemporalIndex].confidence
        )
        let rightTemporal = Keypoint(
            point: LandmarkCoordinates.mediapipePointToUIKit(
                faceLandmarks[GazeAnalyzer.rightTemporalIndex].point
            ),
            confidence: faceLandmarks[GazeAnalyzer.rightTemporalIndex].confidence
        )
        let noseTip = Keypoint(
            point: LandmarkCoordinates.mediapipePointToUIKit(
                faceLandmarks[GazeAnalyzer.noseTipIndex].point
            ),
            confidence: faceLandmarks[GazeAnalyzer.noseTipIndex].confidence
        )

        return analyzeKeypoints(
            leftTemporal: leftTemporal,
            rightTemporal: rightTemporal,
            noseTip: noseTip
        )
    }

    // MARK: - Internal (exposed for unit tests)

    /// Geometry-only entry point that accepts pre-converted UIKit keypoints.
    ///
    /// Declared `internal` (not `private`) so unit tests can call it directly
    /// with synthetic `Keypoint` values, bypassing MediaPipe type construction.
    ///
    /// Yaw computation (UIKit-normalised coordinates, top-left origin 0–1):
    /// ```
    /// faceMidX       = (leftTemporalX + rightTemporalX) / 2
    /// faceWidthX     = abs(rightTemporalX - leftTemporalX)
    /// noseMidOffsetX = noseTipX - faceMidX
    /// yawFraction    = noseMidOffsetX / faceWidthX   // ≈ [-0.5, 0.5]
    /// ```
    ///
    /// - Parameters:
    ///   - leftTemporal: Left temporal landmark in UIKit-normalised coordinates.
    ///   - rightTemporal: Right temporal landmark in UIKit-normalised coordinates.
    ///   - noseTip: Nose tip landmark in UIKit-normalised coordinates.
    /// - Returns: A `BodySignal`, or `nil` if any landmark fails the confidence
    ///   floor or face geometry is degenerate (zero face width).
    func analyzeKeypoints(
        leftTemporal: Keypoint,
        rightTemporal: Keypoint,
        noseTip: Keypoint
    ) -> BodySignal? {
        // Apply confidence floor to each reference landmark individually.
        guard
            let filteredLeft  = KeypointFilter.filter(leftTemporal,  floor: keypointConfidenceFloor),
            let filteredRight = KeypointFilter.filter(rightTemporal, floor: keypointConfidenceFloor),
            let filteredNose  = KeypointFilter.filter(noseTip,       floor: keypointConfidenceFloor)
        else {
            return nil
        }

        // Derive face midline and width from the two temporal landmarks.
        let faceMidX   = (filteredLeft.point.x + filteredRight.point.x) / 2.0
        let faceWidthX = abs(filteredRight.point.x - filteredLeft.point.x)

        // Guard against degenerate geometry (both temporals at the same x).
        guard faceWidthX > 0 else { return nil }

        let noseMidOffsetX = filteredNose.point.x - faceMidX
        let yawFraction    = Double(noseMidOffsetX) / Double(faceWidthX)

        // Mean confidence over the three reference landmarks.
        let meanConfidence: Float =
            (filteredLeft.confidence + filteredRight.confidence + filteredNose.confidence) / 3.0

        let hint: BodyHint = abs(yawFraction) > yawThreshold ? .gazeAway : .goodBody
        return BodySignal(hint: hint, confidence: meanConfidence, dominantRect: nil)
    }
}
