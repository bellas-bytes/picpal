import CoreImage
import CoreVideo
import Foundation
import MediaPipeTasksVision
import UIKit
import Vision

/// A single coordinate/confidence contract for reference images and live video.
struct BodyTrackerLandmark {
    let x: Float
    let y: Float
    let visibility: Float?
    let presence: Float?
}

struct BodyTrackerResult {
    let joints: [String: LivePoseJoint]
    let subjectCount: Int

    func displayed(isMirrored: Bool) -> BodyTrackerResult {
        guard isMirrored else { return self }
        return BodyTrackerResult(joints: joints.mapValues {
            LivePoseJoint(point: CGPoint(x: 1 - $0.point.x, y: $0.point.y), confidence: $0.confidence)
        }, subjectCount: subjectCount)
    }

    func associatedJoints(personBoxes: [CGRect]) -> [String: LivePoseJoint] {
        guard subjectCount == 1, personBoxes.count == 1 else { return [:] }
        let torso: [VNHumanBodyPoseObservation.JointName] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        let box = personBoxes[0].insetBy(dx: -0.03, dy: -0.03)
        guard torso.allSatisfy({ name in
            guard let joint = joints[name.rawValue.rawValue], joint.confidence >= 0.5 else { return false }
            return box.contains(joint.point)
        }) else { return [:] }
        return joints
    }
}

/// Queue-confined: create and use on a background serial queue, or one detached task.
/// Initialization failures allow the caller to use Vision; inference failures propagate
/// so an unreliable frame cannot silently change trackers.
final class ReferenceBodyTracker {
    private let landmarker: PoseLandmarker
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var convertedBuffer: CVPixelBuffer?
    private var lastTimestamp = -1

    init(video: Bool) throws {
        guard let path = Bundle.main.path(forResource: "pose_landmarker_lite", ofType: "task") else {
            throw MediaPipeLandmarkProbeError.modelNotFound("pose_landmarker_lite.task")
        }
        let options = PoseLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.runningMode = video ? .video : .image
        options.numPoses = 2
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        landmarker = try PoseLandmarker(options: options)
    }

    /// Bake all UIImage orientations, including mirrored ones unsupported by MPImage,
    /// into upright RGB pixels. Vision and MediaPipe must see this same displayed image.
    static func uprightImage(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up, image.cgImage != nil { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    func detect(image: UIImage) throws -> BodyTrackerResult {
        try result(landmarker.detect(image: MPImage(uiImage: Self.uprightImage(image))))
    }

    func detectVideo(image: UIImage, timestampMilliseconds: Int) throws -> BodyTrackerResult {
        try detectVideo(mpImage: MPImage(uiImage: Self.uprightImage(image)), timestampMilliseconds: timestampMilliseconds)
    }

    static func canonicalVideoImage(_ image: CIImage, isMirrored: Bool) -> CIImage {
        guard isMirrored else { return image }
        return image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
            tx: image.extent.minX + image.extent.maxX, ty: 0))
    }

    func detectVideo(pixelBuffer: CVPixelBuffer, timestampMilliseconds: Int, isMirrored: Bool = false) throws -> BodyTrackerResult {
        // Camera buffers are NV12; MediaPipe requires BGRA. Reuse one bounded buffer.
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if convertedBuffer.map({ CVPixelBufferGetWidth($0) != width || CVPixelBufferGetHeight($0) != height }) ?? true {
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw ReferenceSessionError.imageConversionFailed }
            convertedBuffer = buffer
        }
        guard let convertedBuffer else { throw ReferenceSessionError.imageConversionFailed }
        context.render(Self.canonicalVideoImage(CIImage(cvPixelBuffer: pixelBuffer), isMirrored: isMirrored), to: convertedBuffer)
        return try detectVideo(mpImage: MPImage(pixelBuffer: convertedBuffer), timestampMilliseconds: timestampMilliseconds)
            .displayed(isMirrored: isMirrored)
    }

    private func detectVideo(mpImage: MPImage, timestampMilliseconds: Int) throws -> BodyTrackerResult {
        let next = max(timestampMilliseconds, lastTimestamp + 1)
        lastTimestamp = next
        return try result(landmarker.detect(videoFrame: mpImage, timestampInMilliseconds: next))
    }

    private func result(_ result: PoseLandmarkerResult) -> BodyTrackerResult {
        Self.adapt(result.landmarks.map { pose in
            pose.map { BodyTrackerLandmark(x: $0.x, y: $0.y,
                visibility: $0.visibility?.floatValue, presence: $0.presence?.floatValue) }
        })
    }

    static func adapt(_ poses: [[BodyTrackerLandmark]]) -> BodyTrackerResult {
        guard poses.count == 1, let pose = poses.first, pose.count == 33 else {
            return BodyTrackerResult(joints: [:], subjectCount: poses.count)
        }
        let mapping: [(Int, VNHumanBodyPoseObservation.JointName)] = [
            (11, .leftShoulder), (12, .rightShoulder), (13, .leftElbow), (14, .rightElbow),
            (15, .leftWrist), (16, .rightWrist), (23, .leftHip), (24, .rightHip),
            (25, .leftKnee), (26, .rightKnee), (27, .leftAnkle), (28, .rightAnkle)]
        var joints: [String: LivePoseJoint] = [:]
        for (index, name) in mapping {
            let p = pose[index]
            guard p.x.isFinite, p.y.isFinite, p.x > 0.015, p.x < 0.985, p.y > 0.015, p.y < 0.985,
                  let visibility = p.visibility, let presence = p.presence,
                  visibility.isFinite, presence.isFinite,
                  (0.5...1).contains(visibility), (0.5...1).contains(presence) else { continue }
            joints[name.rawValue.rawValue] = LivePoseJoint(point: CGPoint(x: CGFloat(p.x), y: CGFloat(1 - p.y)),
                                                         confidence: min(visibility, presence))
        }
        return BodyTrackerResult(joints: joints, subjectCount: 1)
    }
}
