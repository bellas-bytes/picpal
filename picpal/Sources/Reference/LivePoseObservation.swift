import Foundation

struct LivePoseJoint: Sendable {
    let point: CGPoint
    let confidence: Float
}

struct LivePoseObservation: Sendable {
    let capturedAt: TimeInterval
    let geometryRevision: UInt64
    let selfie: SelfiePoseObservation?
    let faceBox: CGRect?
    let personBox: CGRect?
    let joints: [String: LivePoseJoint]
    let faceYaw: Float?
    let subjectCount: Int
    let geometry: ReferenceGeometry
    let analysisAvailable: Bool
    let trackingBackend: PoseTrackingBackend
    let detectionSummary: String

    init(capturedAt: TimeInterval, geometryRevision: UInt64, personBox: CGRect?,
         joints: [String: LivePoseJoint], faceYaw: Float? = nil, subjectCount: Int,
         geometry: ReferenceGeometry = ReferenceGeometry(), analysisAvailable: Bool = true,
         trackingBackend: PoseTrackingBackend = .vision, faceBox: CGRect? = nil, detectionSummary: String = "—", selfie: SelfiePoseObservation? = nil) {
        self.capturedAt = capturedAt
        self.geometryRevision = geometryRevision
        self.selfie = selfie
        self.faceBox = faceBox
        self.personBox = personBox
        self.joints = joints
        self.faceYaw = faceYaw
        self.subjectCount = subjectCount
        self.geometry = geometry
        self.analysisAvailable = analysisAvailable
        self.trackingBackend = trackingBackend
        self.detectionSummary = detectionSummary
    }
}

extension LivePoseObservation {
    /// Preserve face evidence when body inference fails, without inventing body joints.
    static func measured(capturedAt: TimeInterval, geometryRevision: UInt64, body: BodyTrackerResult?,
                         personBoxes: [CGRect], faceBoxes: [CGRect], rectanglesAvailable: Bool,
                         facesAvailable: Bool, geometry: ReferenceGeometry, backend: PoseTrackingBackend,
                         selfie: SelfiePoseObservation? = nil) -> Self {
        let clippedPeople = personBoxes.compactMap(ReferenceSession.clippedDetectorBox)
        let clippedFaces = faceBoxes.compactMap(ReferenceSession.clippedDetectorBox)
        // Never discard invalid detections to turn an ambiguous frame into one subject.
        let valid = clippedPeople.count == personBoxes.count && clippedFaces.count == faceBoxes.count
        let person = valid && clippedPeople.count == 1 ? clippedPeople[0] : nil
        let face = valid && clippedFaces.count == 1 ? clippedFaces[0] : nil
        let associated: Bool
        if let person, let face {
            associated = person.insetBy(dx: -0.03, dy: -0.03).contains(CGPoint(x: face.midX, y: face.midY))
        } else { associated = true }
        return Self(capturedAt: capturedAt, geometryRevision: geometryRevision,
            personBox: person, joints: valid ? body?.associatedJoints(personBoxes: clippedPeople) ?? [:] : [:],
            // A failed association means uncertain identity, not a second measured person.
            subjectCount: max(personBoxes.count, faceBoxes.count, body?.subjectCount ?? 0),
            geometry: geometry, analysisAvailable: rectanglesAvailable && facesAvailable && valid && associated,
            trackingBackend: backend, faceBox: associated ? face : nil,
            detectionSummary: "Faces \(faceBoxes.count) · People \(personBoxes.count) · Poses \(body.map { String($0.subjectCount) } ?? "?") · Associated \(associated) · Valid \(valid) · Hands \(selfie?.detectedHandCount ?? 0)/\(selfie?.hands.count ?? 0) usable", selfie: associated ? selfie : nil)
    }
}
