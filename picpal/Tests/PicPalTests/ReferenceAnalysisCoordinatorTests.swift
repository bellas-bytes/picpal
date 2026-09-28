import Foundation
import Testing
@testable import PicPal

struct ReferenceAnalysisCoordinatorTests {
    @Test func transitionsRejectOldEnvelopes() {
        let coordinator = ReferenceAnalysisCoordinator()
        let a = UUID(), b = UUID()
        coordinator.setContext(sessionID: a, generation: 1, image: nil, consented: true, geometryRevision: 0)
        let envelope = ReferenceEnvelope(sessionID: a, generation: 1, requestID: UUID(), capturedAt: 100, geometryRevision: 0)
        #expect(coordinator.accepts(envelope, now: 101, cloudAllowed: true))
        coordinator.setContext(sessionID: b, generation: 2, image: nil, consented: true, geometryRevision: 0)
        #expect(!coordinator.accepts(envelope, now: 101, cloudAllowed: true))
    }
    @Test func consentGeometryDismissalAndAge() {
        let coordinator = ReferenceAnalysisCoordinator()
        let id = UUID()
        let envelope = ReferenceEnvelope(sessionID: id, generation: 1, requestID: UUID(), capturedAt: 100, geometryRevision: 0)
        coordinator.setContext(sessionID: id, generation: 1, image: nil, consented: true, geometryRevision: 0)
        #expect(!coordinator.accepts(envelope, now: 108, cloudAllowed: true))
        #expect(!coordinator.accepts(envelope, now: 101, cloudAllowed: false))
        coordinator.setContext(sessionID: id, generation: 2, image: nil, consented: false, geometryRevision: 0)
        #expect(!coordinator.accepts(envelope, now: 101, cloudAllowed: true))
        coordinator.setContext(sessionID: id, generation: 1, image: nil, consented: true, geometryRevision: 1)
        #expect(!coordinator.accepts(envelope, now: 101, cloudAllowed: true))
        coordinator.setContext(sessionID: nil, generation: 3, image: nil, consented: false, geometryRevision: 1)
        #expect(!coordinator.accepts(envelope, now: 101, cloudAllowed: true))
    }
}

extension ReferenceAnalysisCoordinatorTests {
    @Test func schedulingWaitsForChangesInsteadOfPolling() {
        let coordinator = ReferenceAnalysisCoordinator()
        let signature = SceneSignature(meanLuminance: 0.5, luminanceVariance: 0.01)
        #expect(coordinator.canSchedule(now: 100, signature: signature))
        coordinator.recordDispatch(now: 100, signature: signature)
        #expect(!coordinator.canSchedule(now: 108, signature: signature))
        coordinator.requestVerification()
        #expect(!coordinator.canSchedule(now: 107.9, signature: signature))
        #expect(coordinator.canSchedule(now: 108, signature: signature))
        coordinator.recordDispatch(now: 108, signature: signature)
        #expect(!coordinator.canSchedule(now: 116, signature: signature))
        let changed = SceneSignature(meanLuminance: 0.8, luminanceVariance: 0.01)
        #expect(coordinator.canSchedule(now: 116, signature: changed))
        #expect(coordinator.canSchedule(now: 128, signature: signature), "Expired evidence and errors get a bounded refresh")
        #expect(coordinator.shouldReportBudget())
        #expect(!coordinator.shouldReportBudget())
    }
    @Test func deliveredComparisonInvalidatesAfterSceneChanges() {
        let coordinator = ReferenceAnalysisCoordinator()
        let id = UUID()
        coordinator.setContext(sessionID: id, generation: 1, image: nil, consented: true, geometryRevision: 0)
        let envelope = ReferenceEnvelope(sessionID: id, generation: 1, requestID: UUID(), capturedAt: 100, geometryRevision: 0)
        let initial = SceneSignature(meanLuminance: 0.5, luminanceVariance: 0.01)
        coordinator.recordComparison(envelope, signature: initial, epoch: coordinator.snapshot.epoch)
        #expect(coordinator.invalidateComparison(for: initial) == nil)
        #expect(coordinator.invalidateComparison(for: SceneSignature(meanLuminance: 0.8, luminanceVariance: 0.01)) == envelope)
        #expect(coordinator.invalidateComparison(for: initial) == nil)
    }
    @Test func liveGeometryChangeRetainsReferenceProfileButRevocationDoesNot() {
        let coordinator = ReferenceAnalysisCoordinator()
        let id = UUID()
        coordinator.setContext(sessionID: id, generation: 1, image: nil, consented: true, geometryRevision: 0)
        let profile = ReferenceProfile(schemaVersion: 1, summary: "Pose", features: [])
        coordinator.store(profile, epoch: coordinator.snapshot.epoch)
        coordinator.setContext(sessionID: id, generation: 2, image: nil, consented: true, geometryRevision: 1)
        #expect(coordinator.snapshot.profile == profile)
        coordinator.setContext(sessionID: id, generation: 3, image: nil, consented: false, geometryRevision: 1)
        #expect(coordinator.snapshot.profile == nil)
    }
    @Test func requestCompletionIsClaimedExactlyOnce() {
        let coordinator = ReferenceAnalysisCoordinator()
        let request = UUID()
        #expect(coordinator.beginRequest(request, epoch: coordinator.snapshot.epoch))
        #expect(coordinator.finishRequest(request))
        #expect(!coordinator.finishRequest(request))
    }
    @Test func unchangedContextKeepsEpoch() {
        let coordinator = ReferenceAnalysisCoordinator()
        let id = UUID()
        #expect(coordinator.setContext(sessionID: id, generation: 1, image: nil, consented: true, geometryRevision: 0))
        let epoch = coordinator.snapshot.epoch
        #expect(!coordinator.setContext(sessionID: id, generation: 1, image: nil, consented: true, geometryRevision: 0))
        #expect(coordinator.snapshot.epoch == epoch)
    }
}

extension ReferenceAnalysisCoordinatorTests {
    @Test func referenceTransportHasExplicitOperationAndImageRoles() {
        let client = AnthropicVLMClient()
        let profileBody = client.buildMultipartBody(imageJPEG: Data("live-bytes".utf8),
            referenceImageJPEG: Data("reference-bytes".utf8), prompt: "Profile", boundary: "test",
            operation: .referenceProfile)
        let profileText = String(decoding: profileBody, as: UTF8.self)
        #expect(profileText.contains("referenceProfile"))
        #expect(profileText.contains("reference-bytes"))
        #expect(!profileText.contains("live-bytes"))
        #expect(!profileText.contains("name=\"image\""))
        let comparisonBody = client.buildMultipartBody(imageJPEG: Data("live-bytes".utf8),
            referenceImageJPEG: Data("reference-bytes".utf8), prompt: "Compare", boundary: "test",
            operation: .referenceComparison, profileJSON: "{\"schemaVersion\":1}")
        let comparisonText = String(decoding: comparisonBody, as: UTF8.self)
        #expect(comparisonText.contains("referenceComparison"))
        #expect(comparisonText.contains("name=\"profile\""))
        #expect(comparisonText.range(of: "reference-bytes")!.lowerBound < comparisonText.range(of: "live-bytes")!.lowerBound)
    }
}

extension ReferenceAnalysisCoordinatorTests {
    @Test func armedRenewalUsesEarliestCadenceAndDisarmReturnsToSparseRefresh() {
        let coordinator = ReferenceAnalysisCoordinator()
        coordinator.recordDispatch(now: 100)
        coordinator.updateArmed(true)
        #expect(!coordinator.canSchedule(now: 107.99))
        #expect(coordinator.canSchedule(now: 108))
        coordinator.recordDispatch(now: 108)
        coordinator.updateArmed(false)
        #expect(!coordinator.canSchedule(now: 116))
        #expect(coordinator.canSchedule(now: 128))
    }
    @Test func referenceBytesSurviveGeometryButNotRevocationOrStaleWorkers() {
        let coordinator = ReferenceAnalysisCoordinator()
        let id = UUID()
        coordinator.setContext(sessionID: id, generation: 1, image: nil, consented: true, geometryRevision: 0)
        let epoch = coordinator.snapshot.epoch
        #expect(coordinator.storeReferenceJPEG(Data([1, 2]), epoch: epoch))
        coordinator.setContext(sessionID: id, generation: 2, image: nil, consented: true, geometryRevision: 1)
        #expect(coordinator.snapshot.referenceJPEG == Data([1, 2]))
        coordinator.setContext(sessionID: id, generation: 3, image: nil, consented: false, geometryRevision: 1)
        #expect(coordinator.snapshot.referenceJPEG == nil)
        #expect(!coordinator.storeReferenceJPEG(Data([3]), epoch: epoch))
        #expect(coordinator.snapshot.referenceJPEG == nil)
        coordinator.setContext(sessionID: id, generation: 4, image: nil, consented: true, geometryRevision: 1)
        #expect(coordinator.storeReferenceJPEG(Data([4]), epoch: coordinator.snapshot.epoch))
        coordinator.setContext(sessionID: UUID(), generation: 5, image: nil, consented: true, geometryRevision: 1)
        #expect(coordinator.snapshot.referenceJPEG == nil, "Replacing reference identity clears encoded bytes")
    }
}
