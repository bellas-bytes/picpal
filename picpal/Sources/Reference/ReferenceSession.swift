import UIKit
import ImageIO
import Vision

// MARK: - ReferenceSessionError

/// Errors that can surface from pose-extraction operations.
enum ReferenceSessionError: Error {
    /// The image contains no detectable human body pose.
    case noPoseDetected
    /// The `UIImage` could not be converted to a `CGImage` for Vision processing.
    case imageConversionFailed
    /// Vision could not finish analyzing the selected image.
    case analysisFailed
}

// MARK: - Private constants


// MARK: - ReferenceSession

/// Owns the active reference photo and its extracted `ReferencePose`.
///
/// Create one when the user picks a reference image; call `extractPose()` to run
/// Vision body-pose and face analysis asynchronously. Discard the session when the
/// user dismisses the reference picker.
///
/// ## Threading
/// The class is `@MainActor`-isolated. All Vision work is dispatched to a detached
/// background task so the main thread is never blocked. The `visionExtractor` closure
/// must be `@Sendable` to satisfy Swift 6 strict concurrency.
@MainActor
final class ReferenceSession: ObservableObject {

    // MARK: - Published state

    /// The selected reference image. Immutable after init.
    let id = UUID()
    let image: UIImage

    /// The extracted pose, set on completion of `extractPose()`. Nil if extraction is
    /// pending or failed.
    @Published private(set) var pose: ReferencePose?

    /// The last extraction error, or `nil` when extraction is pending, has not been run,
    /// or completed successfully.
    @Published private(set) var extractionError: ReferenceSessionError?

    /// True while Vision inference is running; false otherwise.
    @Published private(set) var isExtracting: Bool = false

    // MARK: - Injectable extractor

    /// Closure that performs the actual Vision inference.
    ///
    /// Production code uses the default `ReferenceSession.runVision(on:)` implementation.
    /// Tests inject a fast mock that returns a fixed `ReferencePose` (or throws a
    /// `ReferenceSessionError`) without spawning Vision requests.
    private let visionExtractor: @Sendable (UIImage) throws -> ReferencePose

    // MARK: - Init

    /// Creates a session for the given image.
    ///
    /// - Parameters:
    ///   - image: The reference photo selected by the user.
    ///   - visionExtractor: Replaces the production Vision implementation in tests.
    ///     Defaults to `ReferenceSession.runVision(on:)`.
    init(
        image: UIImage,
        visionExtractor: @escaping @Sendable (UIImage) throws -> ReferencePose = ReferenceSession.runVision(on:)
    ) {
        self.image = image.imageOrientation == .up ? image : ReferenceBodyTracker.uprightImage(image)
        self.visionExtractor = visionExtractor
    }

    // MARK: - Pose extraction

    /// Runs Vision body-pose and face analysis on a detached background queue.
    ///
    /// Sets `isExtracting` to `true` for the duration of inference and `false` on
    /// completion (success or failure). On success, sets `pose` to the extracted
    /// `ReferencePose` and clears `extractionError`. On failure, sets `pose` to `nil`
    /// and stores the `ReferenceSessionError` in `extractionError`.
    func extractPose() async {
        isExtracting = true
        extractionError = nil
        defer { isExtracting = false }
        // Capture values from the main actor before crossing the isolation boundary.
        let capturedImage = image
        let extractor = visionExtractor
        do {
            pose = try await Task.detached(priority: .userInitiated) {
                try extractor(capturedImage)
            }.value
        } catch let error as ReferenceSessionError {
            pose = nil
            extractionError = error
        } catch {
            pose = nil
            extractionError = .analysisFailed
        }
    }

    // MARK: - Vision inference (nonisolated static — runs off main actor)

    /// Performs `VNDetectHumanBodyPoseRequest` and optionally `VNDetectFaceLandmarksRequest`
    /// on the given image. Returns a fully-populated `ReferencePose` on success.
    ///
    /// - Throws: `ReferenceSessionError.imageConversionFailed` when the `UIImage` has no
    ///   backing `CGImage`. Throws `ReferenceSessionError.noPoseDetected` when Vision finds
    ///   no human body or yields no confident keypoints. Other Vision errors propagate as-is.
    ///
    /// Declared `static` to prevent inadvertent capture of `self` inside the detached task.
    /// No Vision types leak into the returned `ReferencePose` — joint names are stored as
    /// their `rawValue` `String`s.
    nonisolated private static func runVision(on sourceImage: UIImage) throws -> ReferencePose {
        let image = ReferenceBodyTracker.uprightImage(sourceImage)
        guard let cgImage = image.cgImage else {
            throw ReferenceSessionError.imageConversionFailed
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        // Face detection is independent: a body tracker failure cannot erase a selfie.
        let faceRequest = VNDetectFaceLandmarksRequest()
        let facesAvailable = (try? handler.perform([faceRequest])) != nil
        let faces = faceRequest.results?.filter { $0.confidence >= 0.5 } ?? []
        let rectangleRequest = VNDetectHumanRectanglesRequest()
        rectangleRequest.upperBodyOnly = false
        let rectanglesAvailable = (try? handler.perform([rectangleRequest])) != nil
        let rectangles = rectangleRequest.results?.filter { $0.confidence >= 0.5 } ?? []
        let tracker = try? ReferenceBodyTracker(video: false)
        let backend: PoseTrackingBackend = tracker == nil ? .vision : .mediaPipe
        var body: BodyTrackerResult?
        if let tracker {
            body = try? tracker.detect(image: image)
        } else {
            let request = VNDetectHumanBodyPoseRequest()
            if (try? handler.perform([request])) != nil {
                let observations = request.results ?? []
                let points = observations.count == 1 ? (try? observations[0].recognizedPoints(.all)) ?? [:] : [:]
                body = BodyTrackerResult(joints: Dictionary(uniqueKeysWithValues: points.map {
                    ($0.key.rawValue.rawValue, LivePoseJoint(point: $0.value.location, confidence: $0.value.confidence))
                }), subjectCount: observations.count)
            }
        }
        guard facesAvailable, rectanglesAvailable else { throw ReferenceSessionError.analysisFailed }
        return try makePose(body: body, faces: faces.map(\.boundingBox), personBoxes: rectangles.map(\.boundingBox),
            geometry: ReferenceGeometry(imageAspectRatio: Double(image.size.width / max(image.size.height, 1))),
            backend: backend, faceYaw: faces.count == 1 ? faces[0].yaw?.floatValue : nil,
            selfie: SelfiePoseTracker.detect(handler: handler, face: faces.count == 1 ? faces[0] : nil,
                imageAspectRatio: Double(image.size.width / max(image.size.height, 1))))
    }

    /// Shared selection logic for independently measured face, person and body evidence.
    nonisolated static func makePose(body: BodyTrackerResult?, faces: [CGRect], personBoxes: [CGRect],
                                    geometry: ReferenceGeometry, backend: PoseTrackingBackend = .vision,
                                    faceYaw: Float? = nil, selfie: SelfiePoseObservation? = nil) throws -> ReferencePose {
        let clippedFaces = faces.compactMap(clippedDetectorBox)
        let clippedPeople = personBoxes.compactMap(clippedDetectorBox)
        guard faces.count <= 1, personBoxes.count <= 1, (body?.subjectCount ?? 0) <= 1,
              clippedFaces.count == faces.count, clippedPeople.count == personBoxes.count else {
            throw ReferenceSessionError.noPoseDetected
        }
        let faces = clippedFaces
        let personBoxes = clippedPeople
        let face = faces.first
        if let face, let person = personBoxes.first,
           !person.insetBy(dx: -0.03, dy: -0.03).contains(CGPoint(x: face.midX, y: face.midY)) {
            throw ReferenceSessionError.noPoseDetected
        }
        let joints = body?.associatedJoints(personBoxes: personBoxes) ?? [:]
        let domain: ReferenceFramingDomain = joints.isEmpty && face != nil ? .face : .person
        guard let box = domain == .face ? face : personBoxes.first else {
            throw ReferenceSessionError.noPoseDetected
        }
        return ReferencePose(bodyKeypoints: joints.mapValues(\.point),
            faceCenter: face.map { CGPoint(x: $0.midX, y: $0.midY) }, faceYaw: faceYaw,
            subjectBoundingBox: box, subjectCenterX: Float(box.midX), subjectCenterY: Float(box.midY),
            subjectHeightFraction: Float(box.height), headroomFraction: Float(max(0, 1 - box.maxY)),
            jointConfidences: joints.mapValues(\.confidence), geometry: geometry, subjectCount: 1,
            trackingBackend: backend, faceBox: face, framingDomain: domain, selfie: selfie)
    }

    /// Detectors can extend a cropped subject just beyond the image. Preserve its
    /// visible bounds; malformed or entirely offscreen evidence remains invalid.
    nonisolated static func clippedDetectorBox(_ box: CGRect) -> CGRect? {
        guard [box.origin.x, box.origin.y, box.size.width, box.size.height,
               box.maxX, box.maxY].allSatisfy(\.isFinite),
              box.size.width > 0, box.size.height > 0 else { return nil }
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return validBox(clipped) ? clipped : nil
    }

    nonisolated static func validBox(_ box: CGRect) -> Bool {
        [box.origin.x, box.origin.y, box.size.width, box.size.height].allSatisfy(\.isFinite)
            && box.size.width > 0 && box.size.height > 0 && box.minX >= 0 && box.minY >= 0 && box.maxX <= 1 && box.maxY <= 1
    }

    nonisolated static func visionOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
