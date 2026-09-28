import Foundation

/// Single synchronous owner of reference guidance. Caller supplies the monotonic clock.
struct ReferenceCoachingCoordinator {
    private struct Identity: Equatable {
        let session: UUID
        let generation: UInt64
        let revision: UInt64
    }
    private struct Candidate {
        let action: ReferenceAction
        let timestamp: TimeInterval
        let local: Bool
        var key: String { "\(action.dimension.rawValue)|\(action.actor.rawValue)|\(action.direction.lowercased())" + (action.direction.hasPrefix("selfie_") ? "|\(action.instruction)" : "") }
    }

    var policy = ReferenceCoachingPolicy()
    private var identity: Identity?
    private var active: Candidate?
    private var pending: Candidate?
    private var alignedSince: TimeInterval?
    private var lastLocalTime: TimeInterval?
    private var previousNow: TimeInterval?
    private var completedDetail: (key: String, caption: String, until: TimeInterval)?

    mutating func reset() {
        identity = nil
        active = nil
        pending = nil
        alignedSince = nil
        lastLocalTime = nil
        previousNow = nil
        completedDetail = nil
    }

    mutating func update(_ input: ReferenceCoachingInput) -> ReferenceCoachingDecision {
        let nextIdentity = Identity(session: input.sessionID, generation: input.generation, revision: input.geometryRevision)
        if identity != nextIdentity || previousNow.map({ input.now < $0 }) == true { reset() }
        identity = nextIdentity
        previousNow = input.now

        func envelopeValid(_ envelope: ReferenceEnvelope) -> Bool {
            envelope.sessionID == input.sessionID && envelope.generation == input.generation
                && envelope.geometryRevision == input.geometryRevision && envelope.capturedAt.isFinite
                && envelope.capturedAt <= input.now
        }
        let local = input.local.flatMap { evidence in
            evidence.geometryRevision == input.geometryRevision
                && policy.fresh(evidence.capturedAt, now: input.now, maximumAge: policy.localMaxAge) ? evidence : nil
        }
        guard let local, local.analysisAvailable else {
            clearObservationHistory()
            return decision(.unavailable, "Waiting for a clear view", explanation: "Local observations are unavailable.")
        }
        guard local.subjectPresent && local.subjectCount == 1 else {
            clearObservationHistory()
            return decision(.unsupported, local.subjectCount > 1 ? "Keep one person in view" : "Bring the person into view")
        }

        let locallyAligned = local.framingAligned && local.poseAligned == true
            && !local.dimensions.contains { $0.status == .different }
        if !locallyAligned || lastLocalTime.map({ local.capturedAt < $0 || local.capturedAt - $0 > policy.maximumObservationGap }) == true {
            alignedSince = nil
        }
        if locallyAligned && alignedSince == nil { alignedSince = local.capturedAt }
        lastLocalTime = local.capturedAt

        let cloudEnabled = input.cloudAvailability == .available
        let profile = cloudEnabled ? input.profile.flatMap { envelopeValid($0.envelope) ? $0.value : nil } : nil
        let comparison = cloudEnabled ? input.comparison.flatMap {
            envelopeValid($0.envelope) && policy.fresh($0.envelope.capturedAt, now: input.now, maximumAge: policy.comparisonMaxAge) ? $0 : nil
        } : nil
        var effectiveDimensions = comparison?.value.dimensions ?? []
        // Framing shares a measurement domain. Local pose covers only some limbs/torso;
        // its positive result cannot erase semantic head, hand or depth differences.
        for observed in local.dimensions where policy.supported(observed)
            && ((observed.dimension == .framing && (observed.status == .matched || observed.status == .different))
                || (observed.dimension == .pose && observed.status == .different)) {
            effectiveDimensions.removeAll { $0.dimension == observed.dimension }
            effectiveDimensions.append(observed)
        }

        var candidates: [Candidate] = []
        if let action = local.action, policy.supported(action, dimensions: local.dimensions) {
            candidates.append(Candidate(action: action, timestamp: local.capturedAt, local: true))
        }
        if let comparison, let action = comparison.value.action,
           policy.supported(action, dimensions: comparison.value.dimensions),
           policy.supported(action, dimensions: effectiveDimensions) {
            candidates.append(Candidate(action: action, timestamp: comparison.envelope.capturedAt, local: false))
        }
        if let current = active, current.local, current.action.direction.hasPrefix("selfie_"),
           !local.availablePoseDetails.contains(current.action.direction) { active = nil; pending = nil }
        if let completedDetail, input.now > completedDetail.until || !local.alignedPoseDetails.contains(completedDetail.key) {
            self.completedDetail = nil
        }
        var detailProgress: String? = completedDetail?.caption
        if let current = active, current.local, current.action.direction.hasPrefix("selfie_"),
           local.alignedPoseDetails.contains(current.action.direction), local.capturedAt > current.timestamp {
            let detail = current.action.direction.replacingOccurrences(of: "selfie_", with: "").replacingOccurrences(of: "_", with: " ")
            detailProgress = "Your \(detail) now aligns"
            completedDetail = (current.action.direction, detailProgress!, input.now + 2)
            active = nil; pending = nil
        }
        let oldAction = active
        if let current = active {
            let maximumAge = current.local ? policy.localMaxAge : policy.comparisonMaxAge
            if !policy.fresh(current.timestamp, now: input.now, maximumAge: maximumAge)
                || (!current.local && !cloudEnabled) { active = nil; pending = nil }
        }
        var progress: String? = detailProgress
        if let current = active {
            // Verify in the same evidence domain that supplied the action. Direct framing
            // can verify cloud framing, but partial local pose cannot verify semantic pose.
            let useLocal = current.local || current.action.dimension == .framing
            let observations = useLocal ? local.dimensions : comparison?.value.dimensions ?? []
            let observedAt = useLocal ? local.capturedAt : comparison?.envelope.capturedAt
            if let observation = observations.first(where: { $0.dimension == current.action.dimension }),
               observation.status == .matched, policy.supported(observation),
               !effectiveDimensions.contains(where: { $0.dimension == current.action.dimension && $0.status == .different }),
               let observedAt, observedAt > current.timestamp {
                let scope = current.local && current.action.dimension == .pose ? "Measured pose" : current.action.dimension.rawValue.capitalized
                progress = "\(scope) now aligns with the reference."
                active = nil
                pending = nil
            }
        }
        if let candidate = candidates.first {
            if let current = active, candidate.key != current.key {
                if candidate.local && !current.local && candidate.action.dimension == current.action.dimension {
                    // Direct observations override conflicting cloud inference immediately.
                    active = candidate
                    pending = nil
                } else if candidate.timestamp <= current.timestamp {
                    pending = nil
                } else if let pending, pending.key == candidate.key, candidate.timestamp > pending.timestamp {
                    active = candidate
                    self.pending = nil
                } else if pending?.key != candidate.key {
                    pending = candidate
                }
            } else {
                if let current = active {
                    if candidate.timestamp >= current.timestamp { active = candidate }
                } else {
                    active = candidate
                }
                pending = nil
            }
        } else {
            // A new unknown or unsupported observation must not preserve a previous instruction.
            active = nil
            pending = nil
        }

        if let active {
            return decision(cloudEnabled ? .guiding : cloudPhase(input.cloudAvailability), active.action.instruction,
                            explanation: detailProgress ?? active.action.expectedChange, action: normalized(active), framing: local.framingAligned,
                            target: active.action.instruction == local.action?.instruction ? local.guidanceTarget : nil, progress: detailProgress)
        }
        if !cloudEnabled {
            let unavailable = cloudPhase(input.cloudAvailability)
            let caption: String
            if !local.framingAligned { caption = "Comparing framing" }
            else if local.poseAligned == true { caption = "Measured pose and framing aligned" }
            else if local.poseAligned == false { caption = "Pose differs from the reference" }
            else if local.framingDomain == .face { caption = local.progressCaption ?? "Face framing aligned" }
            else { caption = "Show the full pose clearly" }
            return decision(unavailable, caption,
                            explanation: unavailable == .localOnly ? "Local guidance only; overall reference matching is unavailable." : "Cloud comparison is unavailable. Local guidance remains available.",
                            framing: local.framingAligned, progress: detailProgress ?? local.progressCaption)
        }
        guard let profile else {
            return decision(.reading, "Reading the reference", framing: local.framingAligned, progress: detailProgress)
        }
        guard let comparison else {
            return decision(input.comparison == nil && oldAction == nil ? .comparing : .verifying,
                            "Checking the reference", framing: local.framingAligned, progress: detailProgress)
        }
        let supportedMatch = policy.allMatched(profile: profile, comparison: comparison.value)
            && !effectiveDimensions.contains { $0.status == .different || $0.status == .unknown }
        let dwellComplete = locallyAligned && alignedSince.map { local.capturedAt - $0 >= policy.alignmentDwell } == true
        if supportedMatch && dwellComplete {
            return decision(.matched, "Reference matched", framing: true, matched: true, safe: input.captureSafe)
        }
        return decision(.verifying, "Checking the reference", explanation: progress, framing: local.framingAligned, progress: detailProgress)
    }

    private mutating func clearObservationHistory() {
        active = nil
        pending = nil
        alignedSince = nil
        lastLocalTime = nil
        completedDetail = nil
    }

    private func normalized(_ candidate: Candidate) -> ReferenceAction {
        let action = candidate.action
        return ReferenceAction(id: candidate.key, dimension: action.dimension, actor: action.actor,
                               direction: action.direction, instruction: action.instruction,
                               expectedChange: action.expectedChange, confidence: action.confidence)
    }

    private func cloudPhase(_ availability: ReferenceCloudAvailability) -> ReferenceCoachingPhase {
        availability == .localOnly ? .localOnly : .unavailable
    }

    private func decision(_ phase: ReferenceCoachingPhase, _ caption: String, explanation: String? = nil,
                          action: ReferenceAction? = nil, framing: Bool = false, matched: Bool = false,
                          safe: Bool = false, target: PoseGuidanceTarget? = nil, progress: String? = nil) -> ReferenceCoachingDecision {
        ReferenceCoachingDecision(phase: phase, caption: caption, explanation: explanation, action: action,
                                  framingAligned: framing, referenceMatched: matched, guidanceTarget: target, progressCaption: progress, allowsAutoCapture: matched && safe)
    }
}
