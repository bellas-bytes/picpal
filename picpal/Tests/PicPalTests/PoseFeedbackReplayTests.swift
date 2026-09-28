import AVFoundation
import Foundation
import ImageIO
import Testing
import UIKit
import Vision
@testable import PicPal

/// Opt-in raw-pixel replay. The ordinary test run does not claim a real-image evaluation.
struct PoseFeedbackReplayTests {
    private struct Manifest: Decodable { let schemaVersion: Int; let datasetKind: String; let records: [Record] }
    private struct Record: Decodable {
        let id: String; let referenceAsset: String; let liveAsset: String
        let camera: String; let orientation: String; let mirrored: Bool; let zoom: Double
        let selectedDetails: [String]; let frames: [Frame]; let selfieAtMinimumZoom: Bool?
    }
    private struct Frame: Decodable { let timestamp: Double }
    private enum ReplayError: Error { case invalid(String) }

    @Test func replayPrivateRawAssetsWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifestPath = env["POSE_REPLAY_MANIFEST"] else { return }
        guard let rootPath = env["POSE_REPLAY_ASSET_ROOT"], let output = env["POSE_REPLAY_OUTPUT"],
              let revision = env["POSE_REPLAY_REVISION"], !revision.isEmpty else {
            throw ReplayError.invalid("Set POSE_REPLAY_ASSET_ROOT, POSE_REPLAY_OUTPUT and POSE_REPLAY_REVISION")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifestPath)))
        guard manifest.schemaVersion == 1, manifest.datasetKind == "real", !manifest.records.isEmpty else {
            throw ReplayError.invalid("Replay requires a validated nonempty real manifest")
        }
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().standardizedFileURL
        func asset(_ path: String) throws -> URL {
            let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  url.path.hasPrefix(root.path + "/") else { throw ReplayError.invalid("Asset outside private root") }
            return url
        }
        var lines: [Data] = []
        for record in manifest.records {
            let tracker = try ReferenceBodyTracker(video: false)
            guard let referenceImage = UIImage(contentsOfFile: try asset(record.referenceAsset).path) else {
                throw ReplayError.invalid("Cannot decode reference \(record.id)")
            }
            let measuredReference = try measure(referenceImage, tracker: tracker, timestamp: 0, mirrored: record.mirrored)
            let reference = try makeReference(measuredReference)
            let url = try asset(record.liveAsset)
            let still = UIImage(contentsOfFile: url.path)
            let generator = still == nil ? AVAssetImageGenerator(asset: AVURLAsset(url: url)) : nil
            generator?.appliesPreferredTrackTransform = true
            generator?.requestedTimeToleranceBefore = .zero
            generator?.requestedTimeToleranceAfter = .zero
            var comparator = ReferenceLocalComparator()
            var coordinator = ReferenceCoachingCoordinator()
            let session = UUID()
            var previousAssetTime: Double?
            for frame in record.frames {
                let image: UIImage
                var actualTime = frame.timestamp
                if let still { image = still }
                else if let generator {
                    let result = try await generator.image(at: CMTime(seconds: frame.timestamp, preferredTimescale: 60000))
                    image = UIImage(cgImage: result.image); actualTime = result.actualTime.seconds
                    guard actualTime.isFinite, previousAssetTime.map({ actualTime > $0 }) ?? true else {
                        throw ReplayError.invalid("Repeated or nonmonotonic clip frame; choose frame-aligned timestamps")
                    }
                    previousAssetTime = actualTime
                } else { throw ReplayError.invalid("Cannot decode live asset") }
                let start = ProcessInfo.processInfo.systemUptime
                let live = try measure(image, tracker: tracker, timestamp: frame.timestamp, mirrored: record.mirrored)
                let selected = Set(record.selectedDetails.compactMap(detailKey))
                guard selected.count == record.selectedDetails.count else { throw ReplayError.invalid("Unsupported focus detail") }
                let local = comparator.compare(reference: reference, live: live,
                    selfieAtMinimumZoom: record.camera == "front" && record.selfieAtMinimumZoom == true, selected: selected)
                let decision = coordinator.update(.init(sessionID: session, generation: 1, geometryRevision: 1,
                    now: frame.timestamp, local: local, cloudAvailability: .localOnly, captureSafe: true))
                let detail = decision.action.flatMap { $0.direction.hasPrefix("selfie_") ? $0.direction.replacingOccurrences(of: "selfie_", with: "") : nil }
                let completed = completedDetails(progressCaption: decision.progressCaption)
                let row: [String: Any] = ["id": record.id, "timestamp": frame.timestamp, "actualAssetTimestamp": actualTime,
                    "action": decision.action?.id as Any? ?? NSNull(), "detail": detail as Any? ?? NSNull(),
                    "completedDetails": completed, "allowsAutoCapture": decision.allowsAutoCapture,
                    "referenceMatched": decision.referenceMatched, "caption": decision.caption,
                    "phase": decision.phase.rawValue,
                    "actionDirection": decision.action?.direction as Any? ?? NSNull(),
                    "actionInstruction": decision.action?.instruction as Any? ?? NSNull(),
                    "localActionID": local.action?.id as Any? ?? NSNull(), "confidence": decision.action?.confidence as Any? ?? NSNull(),
                    "confidenceProvenance": "heuristic evidence quality; uncalibrated",
                    "appRevision": revision, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "device": env["SIMULATOR_MODEL_IDENTIFIER"] ?? "physical-device-unspecified",
                    "detectors": "Vision face landmarks + human rectangles + hand pose; MediaPipe lite image mode",
                    "orientation": record.orientation, "mirrored": record.mirrored, "zoom": record.zoom,
                    "pixelContract": "upright displayed pixels; metadata records capture context; no additional mirroring",
                    "processingLatencyMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    "availableDetails": Array(local.availablePoseDetails).sorted(),
                    "alignedDetails": Array(local.alignedPoseDetails).sorted(), "detectionSummary": live.detectionSummary]
                var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10); lines.append(data)
            }
        }
        try lines.reduce(into: Data()) { $0.append($1) }.write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    /// Reuse the production face/person selection rule, including partial-body fallback.
    private func makeReference(_ measured: LivePoseObservation) throws -> ReferencePose {
        guard measured.analysisAvailable, measured.subjectCount == 1 else {
            throw ReplayError.invalid("Reference detection unavailable/ambiguous")
        }
        return try ReferenceSession.makePose(
            body: BodyTrackerResult(joints: measured.joints, subjectCount: measured.subjectCount),
            faces: measured.faceBox.map { [$0] } ?? [], personBoxes: measured.personBox.map { [$0] } ?? [],
            geometry: measured.geometry, backend: measured.trackingBackend,
            faceYaw: measured.faceYaw, selfie: measured.selfie)
    }

    /// Completion can remain visible while a different cue becomes active. Derive
    /// the exported detail from that visible progress, not the current/previous cue.
    private func completedDetails(progressCaption: String?) -> [String] {
        let details = PoseDetailKey.allCases.map { $0.evidenceKey.replacingOccurrences(of: "selfie_", with: "") } + ["gesture"]
        return details.compactMap { detail in
            return progressCaption == "Your \(detail.replacingOccurrences(of: "_", with: " ")) now aligns" ? detail : nil
        }
    }

    @Test func replayReferenceUsesFaceDomainWhenPersonRectangleHasNoUsableJoints() throws {
        let face = CGRect(x: 0.35, y: 0.6, width: 0.3, height: 0.25)
        let person = CGRect(x: 0.2, y: 0.05, width: 0.6, height: 0.9)
        let measured = LivePoseObservation(capturedAt: 0, geometryRevision: 1, personBox: person,
            joints: [:], subjectCount: 1, faceBox: face)
        let reference = try makeReference(measured)
        #expect(reference.framingDomain == .face)
        #expect(abs(reference.subjectBoundingBox.minX - face.minX) < 0.000001)
        #expect(abs(reference.subjectBoundingBox.minY - face.minY) < 0.000001)
        #expect(abs(reference.subjectBoundingBox.width - face.width) < 0.000001)
        #expect(abs(reference.subjectBoundingBox.height - face.height) < 0.000001)
    }

    @Test func replayRetainsCompletedDetailWhileAnotherCueIsActive() {
        let caption = "Your hand position now aligns"
        let nextAction = ReferenceAction(id: "selfie_head_tilt_left", dimension: .pose, actor: .subject,
            direction: "selfie_head_tilt", instruction: "Tilt your head left",
            expectedChange: "Match head tilt", confidence: 0.9)
        let decision = ReferenceCoachingDecision(phase: .guiding, caption: nextAction.instruction,
            explanation: nil, action: nextAction, framingAligned: true, referenceMatched: false,
            progressCaption: caption, allowsAutoCapture: false)
        #expect(completedDetails(progressCaption: decision.progressCaption) == ["hand_position"])
        #expect(completedDetails(progressCaption: "Getting closer").isEmpty)
        #expect(completedDetails(progressCaption: nil).isEmpty)
        #expect(completedDetails(progressCaption: "Your gesture now aligns") == ["gesture"])
    }

    private func detailKey(_ value: String) -> PoseDetailKey? {
        switch value {
        case "hand_position": return .handPosition
        case "head_tilt": return .headTilt
        case "head_turn": return .headTurn
        case "finger_spread": return .fingerSpread
        case "hand_roll": return .handRoll
        case "shoulder_tilt": return .shoulderTilt
        default: return nil
        }
    }

    private func measure(_ source: UIImage, tracker: ReferenceBodyTracker, timestamp: Double, mirrored: Bool) throws -> LivePoseObservation {
        let image = ReferenceBodyTracker.uprightImage(source)
        guard let cg = image.cgImage else { throw ReplayError.invalid("Missing pixels") }
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        let faces = VNDetectFaceLandmarksRequest()
        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        let facesAvailable = (try? handler.perform([faces])) != nil
        let peopleAvailable = (try? handler.perform([people])) != nil
        let detectedFaces = (faces.results ?? []).filter { $0.confidence >= 0.5 }
        let detectedPeople = (people.results ?? []).filter { $0.confidence >= 0.5 }
        let face = detectedFaces.count == 1 ? detectedFaces.first : nil
        let aspect = Double(cg.width) / Double(cg.height)
        let selfie = SelfiePoseTracker.detect(handler: handler, face: face, imageAspectRatio: aspect)
        let body = try tracker.detect(image: image)
        return .measured(capturedAt: timestamp, geometryRevision: 1, body: body,
            personBoxes: detectedPeople.map(\.boundingBox), faceBoxes: detectedFaces.map(\.boundingBox),
            rectanglesAvailable: peopleAvailable, facesAvailable: facesAvailable,
            geometry: ReferenceGeometry(imageAspectRatio: aspect, isMirrored: mirrored), backend: .mediaPipe, selfie: selfie)
    }
}
