import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Vision

/// Observes unchanged scenes independently of the existing scene-change gate.
/// Mutable scheduling state is protected by `lock`; Vision runs on one private queue.
final class SubjectObservationMonitor: CameraFrameDelegate, @unchecked Sendable {
    private let downstream: any CameraFrameDelegate
    private let onObservation: @Sendable (SubjectObservation) -> Void
    private let onLivePose: @Sendable (LivePoseObservation) -> Void
    private var geometryRevision: UInt64 = 0
    private var isMirrored = false
    private var previewAspectRatio: Double?
    private let queue = DispatchQueue(label: "com.picpal.subject-observation", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var lastScheduled: TimeInterval = -.infinity
    // Accessed only by queue; geometry changes discard video tracking history.
    private var tracker: ReferenceBodyTracker?
    private var trackerRevision: UInt64?

    init(downstream: any CameraFrameDelegate,
         onObservation: @escaping @Sendable (SubjectObservation) -> Void,
         onLivePose: @escaping @Sendable (LivePoseObservation) -> Void = { _ in }) {
        self.downstream = downstream
        self.onObservation = onObservation
        self.onLivePose = onLivePose
    }

    /// Call whenever capture mirroring, zoom, or preview crop changes. Metadata is
    /// snapshotted with each frame so in-flight old results retain their old revision.
    func updateGeometry(revision: UInt64, isMirrored: Bool, previewAspectRatio: Double? = nil) {
        lock.lock()
        geometryRevision = revision
        self.isMirrored = isMirrored
        self.previewAspectRatio = previewAspectRatio
        lock.unlock()
    }

    nonisolated func cameraCapture(_ capture: CameraCapture, didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
                                   timestamp: CMTime) {
        downstream.cameraCapture(capture, didOutputPixelBuffer: pixelBuffer, timestamp: timestamp)
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        guard !busy, now - lastScheduled >= 1.0 / 3.0 else {
            lock.unlock()
            return
        }
        busy = true
        lastScheduled = now
        let revision = geometryRevision
        let geometry = ReferenceGeometry(
            imageAspectRatio: Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(CVPixelBufferGetHeight(pixelBuffer)),
            viewportAspectRatio: previewAspectRatio, isMirrored: isMirrored)
        lock.unlock()
        let frame = RetainedFrame(pixelBuffer: pixelBuffer, observedAt: Date().timeIntervalSince1970)
        queue.async { [self, frame] in
            defer {
                lock.lock()
                busy = false
                lock.unlock()
            }
            if trackerRevision != revision {
                tracker = try? ReferenceBodyTracker(video: true)
                trackerRevision = revision
            }
            // Connections deliver upright displayed pixels for the active orientation.
            let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, orientation: .up)
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            let rectanglesAvailable = (try? handler.perform([request])) != nil
            let people = Self.confidentDetections(request.results ?? [])
            let faceRequest = VNDetectFaceLandmarksRequest()
            let facesAvailable = (try? handler.perform([faceRequest])) != nil
            let faces = Self.confidentDetections(faceRequest.results ?? [])
            var result: BodyTrackerResult?
            let backend: PoseTrackingBackend = tracker == nil ? .vision : .mediaPipe
            if let tracker {
                result = try? tracker.detectVideo(pixelBuffer: frame.pixelBuffer,
                    timestampMilliseconds: Int(now * 1_000), isMirrored: geometry.isMirrored)
            } else {
                let poseRequest = VNDetectHumanBodyPoseRequest()
                let poseHandler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer,
                    orientation: geometry.isMirrored ? .upMirrored : .up)
                if (try? poseHandler.perform([poseRequest])) != nil {
                    let poses = poseRequest.results ?? []
                    let points = poses.count == 1 ? (try? poses[0].recognizedPoints(.all)) ?? [:] : [:]
                    result = BodyTrackerResult(joints: Dictionary(uniqueKeysWithValues: points.map {
                        ($0.key.rawValue.rawValue, LivePoseJoint(point: $0.value.location, confidence: $0.value.confidence))
                    }), subjectCount: poses.count).displayed(isMirrored: geometry.isMirrored)
                }
            }
            let person = people.count == 1 ? ReferenceSession.clippedDetectorBox(people[0].boundingBox) : nil
            onLivePose(.measured(capturedAt: frame.observedAt, geometryRevision: revision, body: result,
                personBoxes: people.map(\.boundingBox), faceBoxes: faces.map(\.boundingBox),
                rectanglesAvailable: rectanglesAvailable, facesAvailable: facesAvailable,
                geometry: geometry, backend: backend,
                selfie: SelfiePoseTracker.detect(handler: handler, face: faces.count == 1 ? faces[0] : nil,
                    imageAspectRatio: geometry.imageAspectRatio)))
            // Generic coaching retains its full-person box contract.
            onObservation(SubjectObservation(box: person, confidence: people.first?.confidence ?? 0,
                observedAt: frame.observedAt, analysisAvailable: rectanglesAvailable))
        }
    }

    /// Keep all confident detections until measured() validates and clips them together.
    /// Dropping edge or malformed boxes here can hide a second detected subject.
    static func confidentDetections<T: VNDetectedObjectObservation>(_ observations: [T]) -> [T] {
        observations.filter { $0.confidence >= 0.5 }
    }

    nonisolated func cameraCapture(_ capture: CameraCapture, didChangeState state: CameraCapture.CaptureState) {
        downstream.cameraCapture(capture, didChangeState: state)
    }

    /// Retains an immutable camera buffer across the analysis queue hop.
    private struct RetainedFrame: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let observedAt: TimeInterval
    }
}
