import AVFoundation
import ImageIO
import SwiftUI

/// Coordinates the visible camera. Capture and save are separate so a failed save
/// never discards the original photo or silently takes a replacement.
@MainActor
final class CameraScreenModel: ObservableObject {
    @Published var style: ShotStyle = .fullBody
    @Published private(set) var isArmed = false
    @Published private(set) var progress = 0.0
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = false
    @Published private(set) var caption = "Looking for a person"
    @Published private(set) var referenceDecision: ReferenceCoachingDecision?
    @Published private(set) var referenceGeometryRevision: UInt64 = 0
    private(set) var referenceGeneration: UInt64 = 0
    private(set) var activeReferenceID: UUID?
    private(set) var referenceCloudAllowed = false
    private(set) var referenceComparison: (envelope: ReferenceEnvelope, value: ReferenceComparison)?
    private var referenceProfile: (envelope: ReferenceEnvelope, value: ReferenceProfile)?
    private var referenceFailure: ReferenceAnalysisFailure?
    private var invalidatedReferenceRequests: Set<UUID> = []
    private var referenceCoordinator = ReferenceCoachingCoordinator()
    private var referenceComparator = ReferenceLocalComparator()
    private var livePose: LivePoseObservation?
    private var localReferenceEvidence: LocalReferenceEvidence?
    private var lastComparedAt: TimeInterval?
    private var lastComparedSelfieAtMinimumZoom = false
    private var wasBlocked = false
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var minZoom: CGFloat = 1
    @Published private(set) var displayZoomMultiplier: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1
    @Published private(set) var supportsFlash = false
    @Published var automaticZoom = false
    private var automaticFocus = true
    private var lastFocusPoint: CGPoint?
    private var lastFocusAt: TimeInterval = 0
    @Published var flash: AVCaptureDevice.FlashMode = .off
    @Published var timerSeconds = 0
    @Published private(set) var countdown: Int?
    @Published private(set) var lastPhoto: UIImage?
    @Published private(set) var notice: String?
    @Published var errorMessage: String?
    @Published private(set) var pendingPhoto: Data?
    private var observation: SubjectObservation?
    private var tilt: TiltSignal?
    private var tiltAt: TimeInterval = 0
    private var gentleMotion = false
    private var motionTolerance = CaptureMotionTolerance()
    private var motionAt: TimeInterval = 0
    @Published private(set) var sessionPhotoCount = 0
    private var exposure: ExposureSignal?
    private var exposureAt: TimeInterval = 0
    private var gate = AutoCaptureGate()
    private var captureTask: Task<Void, Never>?
    private var lastSpoken = ""
    private var spokenAt: TimeInterval = 0
    private var lastZoomAt: TimeInterval = 0
    private var enabledCamera: CameraCapture?
    private var interruption = 0
    private var aesthetic: String?
    private var aestheticAt: TimeInterval = 0
    private let readStatus: @MainActor (CameraCapture) async -> CameraHardwareStatus
    private let takePhoto: @MainActor (CameraCapture, AVCaptureDevice.FlashMode) async throws -> Data
    private let writePhoto: @MainActor (Data) async throws -> Void

    init(readStatus: @escaping @MainActor (CameraCapture) async -> CameraHardwareStatus = { await $0.cameraStatus() },
         takePhoto: @escaping @MainActor (CameraCapture, AVCaptureDevice.FlashMode) async throws -> Data = { try await $0.capturePhoto(flashMode: $1) },
         writePhoto: @escaping @MainActor (Data) async throws -> Void = { try await PhotoLibraryWriter.save($0) }) {
        self.readStatus = readStatus
        self.takePhoto = takePhoto
        self.writePhoto = writePhoto
    }

    func receive(_ observation: SubjectObservation) { self.observation = observation }
    func receive(tilt: TiltSignal) {
        self.tilt = tilt
        tiltAt = Date().timeIntervalSince1970
    }
    func receive(motion: MotionReading) {
        gentleMotion = motionTolerance.update(motion)
        motionAt = Date().timeIntervalSince1970
    }
    func receive(exposure: ExposureSignal) {
        self.exposure = exposure
        exposureAt = Date().timeIntervalSince1970
    }
    func receive(aesthetic: String?) {
        guard activeReferenceID == nil else { return }
        self.aesthetic = aesthetic
        aestheticAt = Date().timeIntervalSince1970
    }

    func toggleAutoCapture() {
        if isArmed { disarm(); return }
        guard !isBusy, pendingPhoto == nil else { return }
        gate.arm(); isArmed = true; notice = nil; sessionPhotoCount = 0
    }

    func disarm() {
        gate.disarm()
        isArmed = false
        progress = 0
    }

    func interrupt() {
        interruption += 1
        disarm()
        observation = nil
        invalidateReferenceGeometry()
        if countdown != nil { captureTask?.cancel() }
    }

    func setZoom(_ value: CGFloat, camera: CameraCapture) {
        automaticZoom = false
        disarm()
        invalidateReferenceGeometry()
        camera.setZoom(value)
    }

    func useManualFocus() { automaticFocus = false; disarm() }

    func useAutomaticFocus(camera: CameraCapture) {
        automaticFocus = true
        lastFocusPoint = nil
        camera.enableAutomaticAdjustments()
        disarm()
    }

    func tick(camera: CameraCapture, voice: VoiceCoach, blocked: Bool,
              reference: ReferenceSession?, matchState: ReferenceMatchState,
              previewCoordinates: CameraPreviewCoordinates? = nil) async {
        let generation = interruption
        let hardware = await readStatus(camera)
        guard generation == interruption, !Task.isCancelled else { return }
        isReady = hardware.isReady
        if activeReferenceID != nil, abs(zoom - hardware.zoomFactor) > 0.01 {
            invalidateReferenceGeometry()
        }
        zoom = hardware.zoomFactor
        minZoom = hardware.minZoom
        displayZoomMultiplier = hardware.displayZoomMultiplier
        maxZoom = hardware.maxZoom
        supportsFlash = hardware.supportsFlash
        guard !blocked else {
            if !wasBlocked { interrupt(); voice.stop() }
            wasBlocked = true
            return
        }
        wasBlocked = false
        if activeReferenceID != reference?.id {
            configureReference(reference, cloudAllowed: false)
            voice.stop()
        }
        if hardware.isReady, enabledCamera !== camera {
            camera.enableAutomaticAdjustments()
            enabledCamera = camera
        }
        guard !isBusy, pendingPhoto == nil else { return }
        let now = Date().timeIntervalSince1970
        if automaticFocus, hardware.isReady, !hardware.isAdjusting,
           let observation, now - observation.observedAt < 0.8,
           let box = observation.box, now - lastFocusAt > 1,
           let point = previewCoordinates?.devicePoint(forVisionPoint: CGPoint(x: box.midX, y: box.midY)) {
            // Let the preview layer resolve the active camera's sensor rotation
            // and mirroring, just as it does for a manual focus tap.
            if lastFocusPoint.map({ hypot($0.x - point.x, $0.y - point.y) > 0.08 }) ?? true {
                camera.trackSubject(at: point)
                lastFocusPoint = point
                lastFocusAt = now
            }
        }
        let exposureOK = !hardware.isAdjusting && now - exposureAt < 0.8 && exposure?.level == .ok
        let freshTilt = now - tiltAt < 0.8 ? tilt : nil
        let movementOK = gentleMotion && now - motionAt < 0.8
        let assessment = PersonShotCoach.assess(observation: observation, style: style,
            tilt: freshTilt, isSettled: movementOK, exposureOK: exposureOK, now: now)
        var message = assessment.message
        if message == "Hold steady" { message = "Slow the movement a little" }
        if message == "Let the lighting settle", !hardware.isAdjusting, now - exposureAt < 0.8 {
            if exposure?.level == .underexposed { message = "Move the person into more light" }
            if exposure?.level == .overexposed { message = "Move the person away from harsh light" }
        }
        var ready = assessment.isReady && hardware.isReady && !hardware.isAdjusting
        matchState.isMatched = false
        if let reference {
            let selfieAtMinimumZoom = camera.cameraPosition == .front && hardware.isReady
                && !hardware.isAdjusting && hardware.zoomFactor <= hardware.minZoom + 0.02
            if let livePose, livePose.capturedAt != lastComparedAt
                || selfieAtMinimumZoom != lastComparedSelfieAtMinimumZoom {
                if let pose = reference.pose {
                    localReferenceEvidence = referenceComparator.compare(reference: pose, live: livePose,
                        selfieAtMinimumZoom: selfieAtMinimumZoom)
                } else {
                    // Cloud comparison can still guide an image whose joints Vision
                    // cannot extract. Unknown local pose prevents automatic matching.
                    localReferenceEvidence = LocalReferenceEvidence(capturedAt: livePose.capturedAt,
                        geometryRevision: livePose.geometryRevision, framingAligned: false, poseAligned: nil,
                        dimensions: [], action: nil, subjectPresent: livePose.personBox != nil || livePose.faceBox != nil,
                        analysisAvailable: livePose.analysisAvailable, subjectCount: livePose.subjectCount)
                }
                lastComparedAt = livePose.capturedAt
                lastComparedSelfieAtMinimumZoom = selfieAtMinimumZoom
            }
            // Reference intent determines composition. Generic horizon and exposure targets
            // must not undo deliberate tilt or low-key lighting in the reference.
            let captureSafe = hardware.isReady && !hardware.isAdjusting && movementOK
                && now - exposureAt < 0.8 && exposure != nil
                && now - lastZoomAt >= 0.25 && now - lastFocusAt >= 0.25
            let availability: ReferenceCloudAvailability = referenceCloudAllowed
                ? referenceFailure.map { .unavailable($0) } ?? .available : .localOnly
            let decision = referenceCoordinator.update(ReferenceCoachingInput(
                sessionID: reference.id, generation: referenceGeneration,
                geometryRevision: referenceGeometryRevision, now: now,
                local: localReferenceEvidence, profile: referenceProfile, comparison: referenceComparison,
                cloudAvailability: availability, captureSafe: captureSafe))
            referenceDecision = decision
            message = decision.caption
            if camera.cameraPosition == .front,
               let selfieAdvice = SelfieFramingAdvice.caption(direction: decision.action?.direction,
                   zoom: hardware.zoomFactor, minimumZoom: hardware.minZoom) {
                message = selfieAdvice
            }
            ready = decision.allowsAutoCapture
            matchState.isMatched = decision.referenceMatched
            if reference.isExtracting, localReferenceEvidence == nil { message = "Reading reference" }
            if reference.extractionError != nil, !referenceCloudAllowed {
                message = "Couldn't assess the pose — try another reference or enable cloud coaching"
            }
        }
        if automaticZoom, reference == nil, assessment.allowsAutoZoom,
           !hardware.isAdjusting, now - lastZoomAt > 2,
           let box = observation?.box {
            let proposed = AutomaticZoomPlanner.target(current: zoom, minZoom: hardware.minZoom,
                maxZoom: hardware.maxZoom, box: box, style: style)
            if abs(proposed - zoom) > 0.12 {
                camera.setZoom(proposed)
                lastZoomAt = now
                ready = false
                message = "Adjusting zoom"
            }
        }
        // Give newly adjusted optics time to produce a fresh observation.
        if now - lastZoomAt < 0.25 || now - lastFocusAt < 0.25 { ready = false }
        if ready && isArmed { message = "Keep posing — I'm taking photos" }
        if reference == nil, ready, let aesthetic, now - aestheticAt < 8 { message = aesthetic }
        caption = message
        if message != lastSpoken, now - spokenAt > 4 {
            voice.speak(Cue(text: message, priority: .stability, sourceTier: .tier0))
            lastSpoken = message
            spokenAt = now
        }
        if gate.update(isReady: ready, now: now) { capture(camera: camera, automatic: true) }
        progress = gate.progress
    }

    func configureReference(_ reference: ReferenceSession?, cloudAllowed: Bool) {
        let allowed = reference != nil && cloudAllowed
        guard activeReferenceID != reference?.id || referenceCloudAllowed != allowed else { return }
        activeReferenceID = reference?.id
        referenceCloudAllowed = allowed
        aesthetic = nil
        disarm()
        invalidateReferenceGeometry()
    }

    func invalidateReferenceGeometry() {
        referenceGeneration &+= 1
        referenceGeometryRevision &+= 1
        referenceProfile = nil
        referenceComparison = nil
        referenceFailure = nil
        invalidatedReferenceRequests.removeAll()
        referenceDecision = nil
        localReferenceEvidence = nil
        livePose = nil
        lastComparedAt = nil
        lastComparedSelfieAtMinimumZoom = false
        referenceCoordinator.reset()
        referenceComparator.reset()
        lastSpoken = ""
        spokenAt = 0
        _ = gate.update(isReady: false, now: Date().timeIntervalSince1970)
    }

    @discardableResult
    func receive(livePose: LivePoseObservation) -> Bool {
        guard livePose.geometryRevision == referenceGeometryRevision else { return false }
        let previous = self.livePose
        let moved: Bool
        if let previous, let before = previous.faceBox ?? previous.personBox, let after = livePose.faceBox ?? livePose.personBox {
            let changedJoints = livePose.joints.filter { key, joint in
                guard joint.confidence >= 0.5, let prior = previous.joints[key], prior.confidence >= 0.5 else { return false }
                return hypot(joint.point.x - prior.point.x, joint.point.y - prior.point.y) > 0.035
            }.count
            moved = changedJoints >= 2 || abs(before.midX - after.midX) > 0.03
                || abs(before.midY - after.midY) > 0.03 || abs(before.height - after.height) > 0.04
        } else { moved = previous?.subjectCount != livePose.subjectCount }
        self.livePose = livePose
        if moved, let comparison = referenceComparison {
            receive(referenceAnalysis: .invalidated(comparison.envelope))
        }
        return moved && activeReferenceID != nil
    }

    /// Also supports replay of production observations in integration tests.
    func receive(localReferenceEvidence: LocalReferenceEvidence) {
        guard localReferenceEvidence.geometryRevision == referenceGeometryRevision else { return }
        self.localReferenceEvidence = localReferenceEvidence
    }

    func receive(referenceAnalysis event: ReferenceAnalysisEvent) {
        let envelope: ReferenceEnvelope
        switch event {
        case .profile(let value, _), .comparison(let value, _), .unavailable(let value, _), .invalidated(let value): envelope = value
        }
        guard referenceCloudAllowed, envelope.sessionID == activeReferenceID,
              envelope.generation == referenceGeneration,
              envelope.geometryRevision == referenceGeometryRevision else { return }
        switch event {
        case .profile(_, let profile):
            referenceProfile = (envelope, profile)
            referenceFailure = nil
        case .comparison(_, let comparison):
            guard !invalidatedReferenceRequests.contains(envelope.requestID) else { return }
            referenceComparison = (envelope, comparison)
            referenceFailure = nil
        case .unavailable(_, let failure):
            referenceComparison = nil
            referenceFailure = failure
        case .invalidated:
            invalidatedReferenceRequests.insert(envelope.requestID)
            if referenceComparison?.envelope.requestID == envelope.requestID {
                referenceComparison = nil
                referenceDecision = nil
                referenceCoordinator.reset()
                _ = gate.update(isReady: false, now: Date().timeIntervalSince1970)
            }
        }
    }

    func capture(camera: CameraCapture, automatic: Bool = false) {
        guard isReady, !isBusy, pendingPhoto == nil else { return }
        if !automatic { disarm() }
        isBusy = true
        notice = nil
        let delay = automatic ? 0 : timerSeconds
        let flashMode = flash
        countdown = delay > 0 ? delay : nil
        captureTask = Task {
            defer { isBusy = false; countdown = nil; captureTask = nil }
            do {
                if delay > 0 {
                    for second in stride(from: delay, through: 1, by: -1) {
                        countdown = second
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                try Task.checkCancellation()
                countdown = nil
                let data = try await takePhoto(camera, flashMode)
                pendingPhoto = data
                if let source = CGImageSourceCreateWithData(data as CFData, nil),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 256
                   ] as CFDictionary) {
                    lastPhoto = UIImage(cgImage: thumbnail)
                }
                try await savePending()
                if automatic { sessionPhotoCount += 1 }
            } catch is CancellationError {
                notice = "Timer cancelled"
            } catch { disarm(); errorMessage = error.localizedDescription }
        }
    }

    func retrySave() {
        guard !isBusy, pendingPhoto != nil else { return }
        errorMessage = nil
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await savePending() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func savePending() async throws {
        guard let pendingPhoto else { return }
        try await writePhoto(pendingPhoto)
        self.pendingPhoto = nil
        notice = "Saved to Photos"
    }
}
