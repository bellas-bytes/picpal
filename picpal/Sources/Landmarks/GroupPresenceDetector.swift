import CoreGraphics
import Vision

/// Computes GroupPresence from an array of body pose observations.
/// Called inside LandmarkOrchestratorProbe's probeQueue after Vision inference.
struct GroupPresenceDetector {

    /// Minimum observation-level confidence to count a person.
    static let minimumBodyConfidence: Float = 0.4

    /// Minimum per-joint confidence when deriving a person's bounding box.
    static let minimumJointConfidence: Float = 0.3

    func detect(from observations: [VNHumanBodyPoseObservation]) -> GroupPresence? {
        let qualifiedBoxes = observations
            .filter { $0.confidence >= Self.minimumBodyConfidence }
            .compactMap { boundingBox(for: $0) }
        return makePresence(from: qualifiedBoxes)
    }

    /// Testable entry point -- accepts raw confidence/bounding-box pairs.
    ///
    /// `VNHumanBodyPoseObservation` cannot be constructed in unit tests (Vision private
    /// initialiser). Pass synthetic pairs to exercise `GroupPresenceDetector` logic instead.
    func detect(pairs: [(confidence: Float, boundingBox: CGRect)]) -> GroupPresence? {
        let qualifiedBoxes = pairs
            .filter { $0.confidence >= Self.minimumBodyConfidence }
            .map { $0.boundingBox }
        return makePresence(from: qualifiedBoxes)
    }

    // MARK: - Private helpers

    /// Derives a bounding rect for a single observation from its joint positions.
    ///
    /// Returns `nil` when no joint clears `minimumJointConfidence` (observation
    /// has no usable keypoints). Coordinates are Vision-normalized (y-up).
    private func boundingBox(for observation: VNHumanBodyPoseObservation) -> CGRect? {
        let allPoints = (try? observation.recognizedPoints(.all)) ?? [:]
        let locations = allPoints.values
            .filter { $0.confidence >= Self.minimumJointConfidence }
            .map { $0.location }
        guard locations.count >= 2 else { return nil }
        let xs = locations.map { $0.x }
        let ys = locations.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func makePresence(from qualifiedBoxes: [CGRect]) -> GroupPresence? {
        guard qualifiedBoxes.count >= GroupPresence.minPersonCount else { return nil }
        let union = qualifiedBoxes.reduce(qualifiedBoxes[0]) { $0.union($1) }
        return GroupPresence(
            personCount: qualifiedBoxes.count,
            unionBoundingBox: union,
            spreadFraction: Float(union.width),
            leftMargin: Float(union.minX),
            rightMargin: Float(1.0 - union.maxX),
            headroomFraction: Float(1.0 - union.maxY)  // Vision y-up: 1.0 is top
        )
    }
}
