import CoreGraphics
import Foundation

enum ShotStyle: String, CaseIterable, Sendable {
    case fullBody, portrait
}

struct SubjectObservation: Sendable {
    /// Normalized Vision coordinates, with the origin at bottom left.
    let box: CGRect?
    let confidence: Float
    let observedAt: TimeInterval
    let analysisAvailable: Bool
}

struct ShotAssessment: Sendable, Equatable {
    let message: String
    let isReady: Bool
    let allowsAutoZoom: Bool
    let subjectHeight: CGFloat?
}

enum PersonShotCoach {
    static func assess(observation: SubjectObservation?, style: ShotStyle, tilt: TiltSignal?,
                       isSettled: Bool, exposureOK: Bool, now: TimeInterval) -> ShotAssessment {
        func advice(_ message: String, height: CGFloat? = nil, ready: Bool = false,
                    zoom: Bool = false) -> ShotAssessment {
            ShotAssessment(message: message, isReady: ready, allowsAutoZoom: zoom, subjectHeight: height)
        }
        guard let observation, now.isFinite, observation.observedAt.isFinite,
              now >= observation.observedAt, now - observation.observedAt <= 0.8 else {
            return advice("Looking for a person")
        }
        guard observation.analysisAvailable else { return advice("Person detection is unavailable") }
        guard let box = observation.box else { return advice("I can't see a person yet") }
        guard observation.confidence >= 0.5, box.minX.isFinite, box.minY.isFinite,
              box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            return advice("Looking for a person")
        }
        let height = box.height
        if style == .fullBody {
            if box.minY < 0.035 || box.maxY > 0.965 || height > 0.9 {
                return advice("Step back to include head and feet", height: height)
            }
            if height < 0.45 { return advice("Move closer to the person", height: height) }
        } else {
            if box.maxY > 0.98 { return advice("Leave a little room above the head", height: height) }
            if height < 0.6 { return advice("Move closer for a portrait", height: height) }
        }
        if box.minX < 0.025 || box.maxX > 0.975 || box.midX < 0.25 || box.midX > 0.75 {
            return advice("Bring the person into the frame", height: height)
        }
        guard let tilt, tilt.angleDegrees.isFinite else { return advice("Checking camera position", height: height) }
        if abs(tilt.angleDegrees) > 6 {
            return advice(tilt.angleDegrees > 0 ? "Tilt slightly left" : "Tilt slightly right", height: height)
        }
        guard isSettled else { return advice("Hold steady", height: height) }
        guard exposureOK else { return advice("Let the lighting settle", height: height) }
        return advice("Ready for a photo", height: height, ready: true, zoom: true)
    }

    /// Reference composition replaces generic shot-style targets, while capture safety remains mandatory.
    static func assessReference(observation: SubjectObservation?, pose: ReferencePose?, tilt: TiltSignal?,
                                isSettled: Bool, exposureOK: Bool, now: TimeInterval) -> ShotAssessment {
        func advice(_ message: String, height: CGFloat? = nil, ready: Bool = false) -> ShotAssessment {
            ShotAssessment(message: message, isReady: ready, allowsAutoZoom: ready, subjectHeight: height)
        }
        guard let pose else { return advice("Reading reference") }
        guard let observation, now.isFinite, observation.observedAt.isFinite,
              now >= observation.observedAt, now - observation.observedAt <= 0.8 else {
            return advice("Looking for a person")
        }
        guard observation.analysisAvailable else { return advice("Person detection is unavailable") }
        guard let box = observation.box else { return advice("I can't see a person yet") }
        guard observation.confidence >= 0.5, box.minX.isFinite, box.minY.isFinite,
              box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            return advice("Looking for a person")
        }
        let height = box.height
        guard let tilt, tilt.angleDegrees.isFinite else { return advice("Checking camera position", height: height) }
        if abs(tilt.angleDegrees) > 6 {
            return advice(tilt.angleDegrees > 0 ? "Tilt slightly left" : "Tilt slightly right", height: height)
        }
        guard isSettled else { return advice("Hold steady", height: height) }
        guard exposureOK else { return advice("Let the lighting settle", height: height) }
        guard pose.subjectCenterX.isFinite, pose.subjectCenterY.isFinite,
              pose.subjectHeightFraction.isFinite, pose.subjectHeightFraction > 0,
              pose.headroomFraction.isFinite else { return advice("Reading reference") }
        // Both measurements use Vision's bottom-left origin. Face yaw is unavailable in rectangle observations.
        let delta = PoseDelta(horizontalOffset: Float(box.midX) - pose.subjectCenterX,
            verticalOffset: Float(box.midY) - pose.subjectCenterY,
            headroomDelta: Float(1 - box.maxY) - pose.headroomFraction,
            scaleDelta: pose.subjectHeightFraction - Float(height))
        if delta.isWithinThreshold {
            return advice(ReferenceCoach.CueText.matched, height: height, ready: true)
        }
        return advice(ReferenceCoach().cue(from: delta, isNewMatch: false)?.text ?? "Match the reference framing",
                      height: height)
    }
}
