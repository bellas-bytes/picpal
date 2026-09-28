import Foundation
import Vision

/// Conservative 2D comparison. Local pose support covers the torso and major limb
/// segments only; viewpoint, fingers, depth and lighting remain cloud responsibilities.
struct ReferenceLocalComparator {
    private var wasFramingAligned = false
    private var wasPoseAligned = false
    private var revision: UInt64?
    private var lastTime: TimeInterval?
    static let confidenceFloor: Float = 0.5
    static let framingEntryTolerance = 0.055
    static let framingExitTolerance = 0.075
    static let poseEntryTolerance = 0.24
    static let poseExitTolerance = 0.32
    // Projected 2D bends need a substantial difference before offering advice.
    static let bendEntryTolerance = 40.0 * Double.pi / 180
    static let bendExitTolerance = 50.0 * Double.pi / 180
    static let minimumSegmentLength = 0.12

    mutating func reset() {
        wasFramingAligned = false
        wasPoseAligned = false
        revision = nil
        lastTime = nil
    }

    mutating func compare(reference: ReferencePose, live: LivePoseObservation,
                          selfieAtMinimumZoom: Bool = false) -> LocalReferenceEvidence {
        if revision != live.geometryRevision || lastTime.map({ live.capturedAt - $0 > 1 || live.capturedAt < $0 }) == true {
            reset()
        }
        revision = live.geometryRevision
        lastTime = live.capturedAt
        var framing = false
        var pose: Bool?
        var action: ReferenceAction?
        var selfie = SelfiePoseComparison()
        let box = reference.framingDomain == .face ? live.faceBox : live.personBox
        let present = (live.personBox != nil || live.faceBox != nil) && live.subjectCount > 0
        let supported = live.analysisAvailable && box.map(ReferenceSession.validBox) == true && present && live.subjectCount == 1 && reference.subjectCount == 1
        if supported, let box {
            let target = reference.geometry.aspectFitDisplayBox(reference.subjectBoundingBox, viewportAspectRatio: live.geometry.viewportAspectRatio)
            let actual = live.geometry.displayBox(box)
            let dx = actual.midX - target.midX
            let dy = actual.midY - target.midY
            let dh = actual.height - target.height
            let tolerance = wasFramingAligned ? Self.framingExitTolerance : Self.framingEntryTolerance
            framing = max(abs(dx), abs(dy), abs(dh)) <= tolerance
            if !framing {
                if abs(dh) >= max(abs(dx), abs(dy)) {
                    let closer = dh < 0
                    action = makeAction(.framing, .photographer, closer ? "move_closer" : "move_back",
                                        closer ? "Move closer to match the reference framing" : "Move back to match the reference framing")
                } else if abs(dx) > abs(dy) {
                    // Aim toward the subject's excess displacement; image moves oppositely.
                    let physicalDX = live.geometry.isMirrored ? -dx : dx
                    action = makeAction(.framing, .photographer, physicalDX > 0 ? "aim_right" : "aim_left",
                                        physicalDX > 0 ? "Aim the phone slightly right" : "Aim the phone slightly left")
                } else {
                    action = makeAction(.framing, .photographer, dy > 0 ? "aim_up" : "aim_down",
                                        dy > 0 ? "Aim the phone slightly up" : "Aim the phone slightly down")
                }
            }
            let result = reference.framingDomain == .face ? (nil as Bool?, nil as ReferenceAction?) : comparePose(reference, live)
            pose = result.0
            // Face-relative hand/head measurements remain useful when an arm's-length
            // selfie cannot get any wider. Keep the framing mismatch for capture safety.
            let limitedSelfie = selfieAtMinimumZoom && reference.framingDomain == .face
                && action?.direction == "move_back"
            if framing || limitedSelfie {
                selfie = SelfiePoseComparator.compare(reference: reference, live: live)
                action = selfie.action ?? (limitedSelfie ? action : result.1)
            }
        }
        wasFramingAligned = framing
        wasPoseAligned = pose == true
        let dimensions = [
            ReferenceDimensionComparison(dimension: .framing, status: supported ? (framing ? .matched : .different) : .unknown,
                referenceEvidence: "Subject position and size in the reference frame",
                liveEvidence: supported ? "Measured subject position and size in the preview crop" : "Single subject unavailable", confidence: supported ? 0.9 : 0),
            ReferenceDimensionComparison(dimension: .pose, status: selfie.action != nil ? .different : (pose.map { $0 ? .matched : .different } ?? .unknown),
                referenceEvidence: "Visible torso and major limb geometry",
                liveEvidence: pose == nil ? "Insufficient or ambiguous joint evidence" : "Compared torso-relative limb positions", confidence: selfie.action != nil ? 0.85 : (pose == nil ? 0 : 0.8))
        ]
        return LocalReferenceEvidence(capturedAt: live.capturedAt, geometryRevision: live.geometryRevision,
            framingAligned: framing, poseAligned: pose, dimensions: dimensions, action: action,
            subjectPresent: present, analysisAvailable: live.analysisAvailable, subjectCount: max(live.subjectCount, reference.subjectCount),
            guidanceTarget: selfie.target, progressCaption: selfie.measuredDetails > 0 && selfie.alignedDetails.count == selfie.measuredDetails ? "Measured pose details aligned" : nil,
            availablePoseDetails: selfie.availableDetails, alignedPoseDetails: selfie.alignedDetails, framingDomain: reference.framingDomain)
    }

    private func makeAction(_ dimension: ReferenceDimension, _ actor: ActionActor, _ direction: String, _ instruction: String) -> ReferenceAction {
        ReferenceAction(id: "local_\(direction)", dimension: dimension, actor: actor, direction: direction,
                        instruction: instruction, expectedChange: "Reduce the measured \(dimension.rawValue) difference", confidence: 0.85)
    }

    private func comparePose(_ reference: ReferencePose, _ live: LivePoseObservation) -> (Bool?, ReferenceAction?) {
        guard reference.trackingBackend == live.trackingBackend else { return (nil, nil) }
        typealias Joint = VNHumanBodyPoseObservation.JointName
        func point(_ name: Joint, referenceSide: Bool) -> CGPoint? {
            let key = name.rawValue.rawValue
            let p: CGPoint
            let geometry: ReferenceGeometry
            if referenceSide {
                guard let candidate = reference.bodyKeypoints[key],
                      let confidence = reference.jointConfidences[key], confidence.isFinite,
                      confidence >= Self.confidenceFloor else { return nil }
                p = candidate; geometry = reference.geometry
            } else {
                guard let joint = live.joints[key], joint.confidence.isFinite,
                      joint.confidence >= Self.confidenceFloor else { return nil }
                p = joint.point; geometry = live.geometry
            }
            // An edge point may be cropped or clamped, even when Vision is confident.
            guard p.x > 0.015, p.x < 0.985, p.y > 0.015, p.y < 0.985 else { return nil }
            let c = geometry.canonicalPoint(p)
            return CGPoint(x: c.x * geometry.imageAspectRatio, y: c.y)
        }
        func normalized(_ referenceSide: Bool) -> [Joint: CGPoint]? {
            guard let ls = point(.leftShoulder, referenceSide: referenceSide),
                  let rs = point(.rightShoulder, referenceSide: referenceSide),
                  let lh = point(.leftHip, referenceSide: referenceSide),
                  let rh = point(.rightHip, referenceSide: referenceSide) else { return nil }
            let shoulder = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
            let hip = CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
            let size = hypot(shoulder.x - hip.x, shoulder.y - hip.y)
            guard size > 0.06, abs(ls.x - rs.x) / size > 0.25 else { return nil } // side-on ambiguity
            let names: [Joint] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftElbow, .rightElbow,
                                  .leftWrist, .rightWrist, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
            var output: [Joint: CGPoint] = [:]
            for name in names {
                if let p = point(name, referenceSide: referenceSide) {
                    output[name] = CGPoint(x: (p.x - hip.x) / size, y: (p.y - hip.y) / size)
                }
            }
            return output
        }
        guard let target = normalized(true), let actual = normalized(false) else { return (nil, nil) }
        let tolerance = wasPoseAligned ? Self.poseExitTolerance : Self.poseEntryTolerance
        // Offer a supported visible arm adjustment even when other joints are occluded.
        for (side, shoulder, elbow, wrist) in [("left", Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist),
                                               ("right", Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist)] {
            if let ts = target[shoulder], let tw = target[wrist], let te = target[elbow],
               let ls = actual[shoulder], let lw = actual[wrist], let le = actual[elbow] {
                let delta = (tw.y - ts.y) - (lw.y - ls.y)
                let elbowDelta = (te.y - ts.y) - (le.y - ls.y)
                if abs(delta) > tolerance && delta * elbowDelta > 0 {
                    let raise = delta > 0
                    return (false, makeAction(.pose, .subject, "\(raise ? "raise" : "lower")_\(side)_arm",
                                              "Ask them to \(raise ? "raise" : "lower") their \(side) arm toward the reference pose"))
                }
            }
        }
        func angle(_ points: [Joint: CGPoint], _ first: Joint, _ middle: Joint, _ last: Joint) -> Double? {
            guard let a = points[first], let b = points[middle], let c = points[last] else { return nil }
            let ux = a.x - b.x, uy = a.y - b.y
            let vx = c.x - b.x, vy = c.y - b.y
            let u = hypot(ux, uy), v = hypot(vx, vy)
            guard u > Self.minimumSegmentLength, v > Self.minimumSegmentLength else { return nil }
            let cosine = Double((ux * vx + uy * vy) / (u * v))
            return acos(max(-1.0, min(1.0, cosine)))
        }
        func bendAction(_ side: String, _ part: String, _ first: Joint, _ middle: Joint, _ last: Joint) -> ReferenceAction? {
            guard let expected = angle(target, first, middle, last),
                  let measured = angle(actual, first, middle, last) else { return nil }
            let delta = expected - measured
            let bendTolerance = wasPoseAligned ? Self.bendExitTolerance : Self.bendEntryTolerance
            guard abs(delta) > bendTolerance else { return nil }
            let verb = delta < 0 ? "bend" : "straighten"
            return makeAction(.pose, .subject, "\(verb)_\(side)_\(part)",
                              "Ask them to \(verb) their \(side) \(part) \(delta < 0 ? "more" : "slightly")")
        }
        for (side, shoulder, elbow, wrist) in [("left", Joint.leftShoulder, Joint.leftElbow, Joint.leftWrist),
                                               ("right", Joint.rightShoulder, Joint.rightElbow, Joint.rightWrist)] {
            if let action = bendAction(side, "elbow", shoulder, elbow, wrist) { return (false, action) }
            if let ts = target[shoulder], let tw = target[wrist], let te = target[elbow],
               let ls = actual[shoulder], let lw = actual[wrist], let le = actual[elbow] {
                // Use distance from each shoulder, so torso lean does not become arm advice.
                let delta = abs(tw.x - ts.x) - abs(lw.x - ls.x)
                let elbowDelta = abs(te.x - ts.x) - abs(le.x - ls.x)
                let targetOutward = (tw.x - ts.x) * ts.x > 0
                let liveOutward = (lw.x - ls.x) * ls.x > 0
                if targetOutward && liveOutward && abs(delta) > tolerance && delta * elbowDelta > 0 {
                    let outward = delta > 0
                    return (false, makeAction(.pose, .subject, "move_\(side)_arm_\(outward ? "out" : "in")",
                        "Ask them to move their \(side) arm \(outward ? "farther out to the side" : "closer to their body")"))
                }
            }
        }
        if let tls = target[.leftShoulder], let trs = target[.rightShoulder],
           let als = actual[.leftShoulder], let ars = actual[.rightShoulder] {
            let delta = (tls.x + trs.x - als.x - ars.x) / 2
            if abs(delta) > tolerance {
                // Use image-relative lean to avoid inventing the subject's facing direction.
                let displayDelta = live.geometry.isMirrored ? -delta : delta
                return (false, makeAction(.pose, .subject, displayDelta > 0 ? "lean_image_right" : "lean_image_left",
                    displayDelta > 0 ? "Ask them to lean toward the right side of the image" : "Ask them to lean toward the left side of the image"))
            }
        }
        for (side, hip, knee, ankle) in [("left", Joint.leftHip, Joint.leftKnee, Joint.leftAnkle),
                                        ("right", Joint.rightHip, Joint.rightKnee, Joint.rightAnkle)] {
            if let action = bendAction(side, "knee", hip, knee, ankle) { return (false, action) }
        }
        if let tl = target[.leftAnkle], let tr = target[.rightAnkle],
           let al = actual[.leftAnkle], let ar = actual[.rightAnkle],
           let tlk = target[.leftKnee], let trk = target[.rightKnee],
           let alk = actual[.leftKnee], let ark = actual[.rightKnee],
           let tlh = target[.leftHip], let trh = target[.rightHip],
           let alh = actual[.leftHip], let arh = actual[.rightHip],
           // Crossed legs and non-standing projections do not support stance advice.
           (tl.x - tr.x) * (tlh.x - trh.x) > 0,
           (al.x - ar.x) * (alh.x - arh.x) > 0,
           tl.y < tlk.y, tr.y < trk.y, al.y < alk.y, ar.y < ark.y {
            let delta = abs(tl.x - tr.x) - abs(al.x - ar.x)
            if abs(delta) > tolerance {
                return (false, makeAction(.pose, .subject, delta > 0 ? "widen_stance" : "narrow_stance",
                    delta > 0 ? "Ask them to move their feet farther apart" : "Ask them to bring their feet closer together"))
            }
        }
        guard target.count == 12, actual.count == 12 else { return (nil, nil) }
        for (name, expected) in target {
            guard let measured = actual[name] else { return (nil, nil) }
            if hypot(expected.x - measured.x, expected.y - measured.y) > tolerance {
                // Unsupported articulation is a known difference, with no invented advice.
                return (false, nil)
            }
        }
        return (true, nil)
    }
}
