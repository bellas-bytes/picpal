import AVFoundation
import Testing
import UIKit
@testable import PicPal

@MainActor
struct CameraReferenceCoachingTests {
    @Test func referenceAdviceAppearsBeforeCaptureReady() async {
        let model = CameraScreenModel(readStatus: { _ in Self.hardware })
        let session = ReferenceSession(image: UIImage())
        model.configureReference(session, cloudAllowed: true)
        let now = Date().timeIntervalSince1970
        model.receive(localReferenceEvidence: Self.local(now: now, revision: model.referenceGeometryRevision))
        model.receive(referenceAnalysis: .comparison(envelope(model, session, now), comparison))
        await model.tick(camera: CameraCapture(), voice: VoiceCoach(), blocked: false,
                         reference: session, matchState: ReferenceMatchState())
        #expect(model.caption == "Ask them to lift their left elbow")
        #expect(model.referenceDecision?.referenceMatched == false)
        #expect(model.isReady) // Manual photography is independent of coaching.
    }

    @Test func rectanglesAndGenericAestheticCannotDeclareReferenceMatch() async {
        let model = CameraScreenModel(readStatus: { _ in Self.hardware })
        let session = ReferenceSession(image: UIImage())
        model.configureReference(session, cloudAllowed: false)
        model.receive(localReferenceEvidence: Self.local(now: Date().timeIntervalSince1970,
                                                        revision: model.referenceGeometryRevision))
        model.receive(aesthetic: "Perfect match")
        let match = ReferenceMatchState()
        await model.tick(camera: CameraCapture(), voice: VoiceCoach(), blocked: false,
                         reference: session, matchState: match)
        #expect(!match.isMatched)
        #expect(model.caption != "Perfect match")
        #expect(model.referenceDecision?.allowsAutoCapture == false)
    }

    @Test func replacingReferenceDiscardsLateComparison() {
        let model = CameraScreenModel()
        let old = ReferenceSession(image: UIImage())
        model.configureReference(old, cloudAllowed: true)
        let envelope = envelope(model, old, Date().timeIntervalSince1970)
        model.configureReference(ReferenceSession(image: UIImage()), cloudAllowed: true)
        model.receive(referenceAnalysis: .comparison(envelope, comparison))
        #expect(model.referenceComparison == nil)
    }

    @Test func sceneInvalidationDiscardsDeliveredAndQueuedComparison() {
        let model = CameraScreenModel()
        let session = ReferenceSession(image: UIImage())
        model.configureReference(session, cloudAllowed: true)
        let envelope = envelope(model, session, Date().timeIntervalSince1970)
        model.receive(referenceAnalysis: .comparison(envelope, comparison))
        #expect(model.referenceComparison != nil)
        model.receive(referenceAnalysis: .invalidated(envelope))
        #expect(model.referenceComparison == nil)
        model.receive(referenceAnalysis: .comparison(envelope, comparison))
        #expect(model.referenceComparison == nil)
    }

    private static var hardware: CameraHardwareStatus {
        CameraHardwareStatus(isReady: true, zoomFactor: 1, minZoom: 1, maxZoom: 2,
                             isAdjusting: false, supportsFlash: false)
    }

    private func envelope(_ model: CameraScreenModel, _ session: ReferenceSession,
                          _ now: TimeInterval) -> ReferenceEnvelope {
        ReferenceEnvelope(sessionID: session.id, generation: model.referenceGeneration,
                          requestID: UUID(), capturedAt: now, geometryRevision: model.referenceGeometryRevision)
    }

    private static func local(now: TimeInterval, revision: UInt64) -> LocalReferenceEvidence {
        LocalReferenceEvidence(capturedAt: now, geometryRevision: revision, framingAligned: true,
            poseAligned: nil, dimensions: [], action: nil, subjectPresent: true,
            analysisAvailable: true, subjectCount: 1)
    }

    private var comparison: ReferenceComparison {
        ReferenceComparison(schemaVersion: 1, dimensions: ReferenceDimension.allCases.map {
            ReferenceDimensionComparison(dimension: $0, status: $0 == .pose ? .different : .matched,
                referenceEvidence: "Left elbow raised", liveEvidence: "Left elbow lowered", confidence: 0.95)
        }, action: ReferenceAction(id: "pose-left-elbow", dimension: .pose, actor: .subject,
            direction: "raise left elbow", instruction: "Ask them to lift their left elbow",
            expectedChange: "Left elbow reaches shoulder height", confidence: 0.95))
    }
}
