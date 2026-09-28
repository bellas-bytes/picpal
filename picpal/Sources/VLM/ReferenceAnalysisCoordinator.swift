import Foundation
import UIKit
import os

/// Atomic memory-only reference context. Every mutation invalidates queued/in-flight work.
final class ReferenceAnalysisCoordinator: @unchecked Sendable {
    struct Snapshot: @unchecked Sendable {
        let sessionID: UUID?
        let generation: UInt64
        let image: UIImage?
        let consented: Bool
        let geometryRevision: UInt64
        let profile: ReferenceProfile?
        let referenceJPEG: Data?
        let epoch: UInt64
    }
    private struct State {
        var sessionID: UUID?
        var generation: UInt64 = 0
        var image: UIImage?
        var consented = false
        var geometryRevision: UInt64 = 0
        var profile: ReferenceProfile?
        var referenceJPEG: Data?
        var armed = false
        var epoch: UInt64 = 0
        var settled = false
        var task: Task<Void, Never>?
        var activeRequestID: UUID?
        var lastDispatch: TimeInterval?
        var lastSignature: SceneSignature?
        var needsComparison = true
        var verificationAvailable = true
        var reportedBudget = false
        var deliveredComparison: (ReferenceEnvelope, SceneSignature)?
    }
    private let lock = OSAllocatedUnfairLock(initialState: State())
    var snapshot: Snapshot {
        lock.withLock { Snapshot(sessionID: $0.sessionID, generation: $0.generation, image: $0.image,
            consented: $0.consented, geometryRevision: $0.geometryRevision, profile: $0.profile, referenceJPEG: $0.referenceJPEG, epoch: $0.epoch) }
    }
    var isSettled: Bool { lock.withLock { $0.settled } }
    func updateMotion(isSettled: Bool) {
        lock.withLock {
            if isSettled && !$0.settled && $0.profile != nil { $0.needsComparison = true }
            $0.settled = isSettled
        }
    }
    func updateArmed(_ armed: Bool) { lock.withLock { $0.armed = armed } }
    @discardableResult
    func storeReferenceJPEG(_ data: Data, epoch: UInt64) -> Bool {
        lock.withLock {
            guard $0.epoch == epoch, $0.consented else { return false }
            $0.referenceJPEG = data
            return true
        }
    }
    func requestVerification() { lock.withLock { $0.needsComparison = true; $0.verificationAvailable = true } }
    @discardableResult
    func setContext(sessionID: UUID?, generation: UInt64, image: UIImage?, consented: Bool, geometryRevision: UInt64) -> Bool {
        lock.withLock { state in
            guard state.sessionID != sessionID || state.generation != generation || state.image !== image ||
                  state.consented != consented || state.geometryRevision != geometryRevision else { return false }
            let retainedProfile = state.sessionID == sessionID && state.image === image
                && state.consented && consented ? state.profile : nil
            let retainedJPEG = state.sessionID == sessionID && state.image === image
                && state.consented && consented ? state.referenceJPEG : nil
            state.task?.cancel()
            state.task = nil
            state.activeRequestID = nil
            state.sessionID = sessionID
            state.generation = generation
            state.image = image
            state.consented = consented
            state.geometryRevision = geometryRevision
            state.profile = retainedProfile
            state.referenceJPEG = retainedJPEG
            state.needsComparison = true
            state.verificationAvailable = true
            state.lastSignature = nil
            state.deliveredComparison = nil
            state.reportedBudget = false
            state.epoch &+= 1
            return true
        }
    }
    func canSchedule(now: TimeInterval, signature: SceneSignature? = nil) -> Bool {
        lock.withLock { state in
            guard now.isFinite, state.lastDispatch.map({ now - $0 >= VLMRequestGate.defaultCadenceSeconds }) ?? true else { return false }
            let sceneChanged = signature.map { current in
                state.lastSignature.map { current.isMateriallyDifferent(from: $0) } ?? false
            } ?? false
            // A sparse refresh recovers offline/timeouts and renews expired evidence
            // without continuously spending the eight-second maximum request rate.
            let refreshDue = state.lastDispatch.map { now - $0 >= (state.armed ? VLMRequestGate.defaultCadenceSeconds : VLMOrchestratorConstants.idleRefreshSeconds) } ?? false
            return state.needsComparison || sceneChanged || refreshDue
        }
    }
    func recordDispatch(now: TimeInterval, signature: SceneSignature? = nil) {
        lock.withLock { $0.lastDispatch = now; $0.lastSignature = signature; $0.needsComparison = false }
    }
    func shouldReportBudget() -> Bool {
        lock.withLock { state in
            guard !state.reportedBudget else { return false }
            state.reportedBudget = true
            return true
        }
    }
    func register(_ task: Task<Void, Never>, epoch: UInt64) {
        lock.withLock { state in
            if state.epoch == epoch { state.task = task } else { task.cancel() }
        }
    }
    func beginRequest(_ requestID: UUID, epoch: UInt64) -> Bool {
        lock.withLock {
            guard $0.epoch == epoch else { return false }
            $0.activeRequestID = requestID
            return true
        }
    }
    @discardableResult
    func finishRequest(_ requestID: UUID) -> Bool {
        lock.withLock {
            guard $0.activeRequestID == requestID else { return false }
            $0.activeRequestID = nil
            return true
        }
    }
    func accepts(_ envelope: ReferenceEnvelope, now: TimeInterval, cloudAllowed: Bool) -> Bool {
        lock.withLock { state in
            cloudAllowed && state.consented && state.sessionID == envelope.sessionID &&
            state.generation == envelope.generation && state.geometryRevision == envelope.geometryRevision &&
            now >= envelope.capturedAt && now - envelope.capturedAt < VLMOrchestratorConstants.comparisonFreshnessSeconds
        }
    }
    func store(_ profile: ReferenceProfile, epoch: UInt64) {
        lock.withLock { if $0.epoch == epoch { $0.profile = profile; $0.needsComparison = true } }
    }

    func recordComparison(_ envelope: ReferenceEnvelope, signature: SceneSignature, epoch: UInt64, hasAction: Bool = false) {
        lock.withLock {
            if $0.epoch == epoch {
                $0.deliveredComparison = (envelope, signature)
                if hasAction && $0.verificationAvailable {
                    $0.needsComparison = true
                    $0.verificationAvailable = false
                }
            }
        }
    }

    /// A previously delivered assessment is no longer valid after the scene changes.
    func invalidateComparison(for signature: SceneSignature?) -> ReferenceEnvelope? {
        lock.withLock { state in
            guard let (envelope, previous) = state.deliveredComparison else { return nil }
            guard signature.map({ $0.isMateriallyDifferent(from: previous) }) ?? true else { return nil }
            state.deliveredComparison = nil
            state.needsComparison = true
            return envelope
        }
    }
}
