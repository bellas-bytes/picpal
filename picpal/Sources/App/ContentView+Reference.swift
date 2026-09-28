import SwiftUI

// MARK: - Named constants


// MARK: - ReferenceSessionHandle

/// Stable class reference for the active `ReferenceSession`.
///
/// Declared `@unchecked Sendable` with `nonisolated(unsafe)` storage because:
/// - It is always read and written on `@MainActor`.
/// - It is captured by value in `@Sendable` closures that only ACCESS it through
///   a `Task { @MainActor }` block, so no race can occur.
///
/// Mirrors `AestheticExpiryHandle` — see `ContentView+Session.swift`.
final class ReferenceSessionHandle: @unchecked Sendable {
    /// The current reference session. Always read/written on `@MainActor`.
    nonisolated(unsafe) var session: ReferenceSession? = nil
}

// MARK: - ReferenceMatchState

/// Observable state for per-frame reference match tracking.
///
/// Wraps match count and isMatched as `@Published` properties so SwiftUI views
/// refresh automatically. All access must be on `@MainActor`.
@MainActor
final class ReferenceMatchState: ObservableObject {
    @Published var count: Int = 0
    @Published var isMatched: Bool = false

    func reset() {
        count = 0
        isMatched = false
    }
}

// MARK: - computePoseDelta

/// Maps live body landmarks to a `PoseDelta` against a reference pose.
///
/// Uses `BodySignal.dominantRect` (UIKit-normalized, origin top-left) as a proxy
/// for the live subject's bounding box and compares it with `ReferencePose`'s
/// composition parameters (Vision-normalized, origin bottom-left for Y).
///
/// Coordinate mapping:
/// - X: same direction (0 = left) in both UIKit and Vision.
/// - Y: `UIKit_Y = 1 - Vision_Y`, so live headroom in UIKit ≈ rect.minY.
///
/// Returns all-zero `PoseDelta` when `liveLandmarks.dominantRect` is nil.
///
/// Exposed `internal` so `ReferenceIntegrationTests` can exercise it directly.
internal func computePoseDelta(
    referencePose: ReferencePose,
    liveLandmarks: BodySignal
) -> PoseDelta {
    guard let rect = liveLandmarks.dominantRect else {
        // No subject detected — no coaching possible.
        return PoseDelta(horizontalOffset: 0, verticalOffset: 0,
                         headroomDelta: 0, scaleDelta: 0)
    }

    // Horizontal: X direction is the same in UIKit and Vision.
    let horizontalOffset = Float(rect.midX) - referencePose.subjectCenterX

    // Vertical: convert UIKit midY (y-down) to Vision midY (y-up).
    let liveVisionCenterY = Float(1.0 - rect.midY)
    let verticalOffset = liveVisionCenterY - referencePose.subjectCenterY

    // Headroom: in UIKit, rect.minY is the distance from the top of the frame
    // to the top of the subject — equivalent to Vision headroom (1 - subjectMaxY).
    let headroomDelta = Float(rect.minY) - referencePose.headroomFraction

    // Scale: positive scaleDelta means the live subject is smaller (too far away).
    let scaleDelta = referencePose.subjectHeightFraction - Float(rect.height)

    // BodySignal does not carry face yaw.
    return PoseDelta(
        horizontalOffset: horizontalOffset,
        verticalOffset: verticalOffset,
        headroomDelta: headroomDelta,
        scaleDelta: scaleDelta,
        faceYawDelta: nil
    )
}

// MARK: - ContentView+Reference

extension ContentView {

    // MARK: - Telemetry export

    /// Builds a `TelemetrySnapshot` from current session state and writes it to disk.
    ///
    /// Moved here from `ContentView+Session.swift` to keep that file under 300 lines.
    @MainActor
    func exportSnapshot(surveyResponse: Int?) {
        let report = cueLogger?.makeSummary()
        let batteryReport = batteryMonitor.endSession()
        let stats = vlmOrchestrator?.sessionStats
        let snapshot = TelemetrySnapshot(
            frameStats: FrameTimerStatistics.empty,
            thermalEvents: [],
            batteryReport: batteryReport,
            cueTelemetry: report,
            surveyResponse: surveyResponse,
            vlmCacheHits: stats?.cacheHits,
            vlmCacheMisses: stats?.cacheMisses
        )
        try? telemetryExporter?.export(snapshot: snapshot)
        batteryMonitor.startSession()
    }

    // MARK: - Clear reference state

    /// Tears down all reference-mode state, clears VLMOrchestrator wiring, and
    /// resets the per-frame match counters.
    ///
    /// Call from the overlay dismiss button, swipe-to-dismiss, and background handler.
    func clearReferenceState() {
        referenceSession = nil
        referenceSessionHandle.session = nil
        referenceMatchState.reset()
        referenceCloudConsentGiven = false
        referenceCloudEnabled = false
        cameraScreen.configureReference(nil, cloudAllowed: false)
        voiceCoach.stop()
        syncReferenceAnalysis()
    }

    func syncReferenceAnalysis() {
        let cloudAllowed = referenceCloudEnabled && !VLMSettings.shared.isOnDeviceOnly
        cameraScreen.configureReference(referenceSession, cloudAllowed: cloudAllowed)
        subjectMonitor?.updateGeometry(revision: cameraScreen.referenceGeometryRevision,
            isMirrored: cameraPosition == .front, previewAspectRatio: previewAspectRatio)
        vlmOrchestrator?.setReferenceContext(sessionID: referenceSession?.id,
            generation: cameraScreen.referenceGeneration, image: referenceSession?.image,
            consented: cloudAllowed && !cameraControlsBlocked,
            geometryRevision: cameraScreen.referenceGeometryRevision)
    }

}

extension ContentView {
    func updatePreviewAspect(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = size.width / size.height
        guard abs(previewAspectRatio - aspect) > 0.001 else { return }
        previewAspectRatio = aspect
        cameraScreen.interrupt()
        cameraScreen.invalidateReferenceGeometry()
        referenceMatchState.reset()
        voiceCoach.stop()
        syncReferenceAnalysis()
    }

    func requestPhysicalCameraRotation() {
        guard !cameraScreen.isBusy, !isSwitchingCamera,
              let physicalOrientation,
              let window = previewCoordinates.container?.window,
              let scene = window.windowScene else { return }
        sceneRotation.update(physicalOrientation: physicalOrientation, interfaceOrientation: scene.interfaceOrientation,
                             isActive: scene.activationState == .foregroundActive,
                             hasPresentedController: window.rootViewController?.presentedViewController != nil) { mask in
            #if DEBUG
            print("[PicPal rotation] Request physical=\(physicalOrientation) scene=\(scene.interfaceOrientation.rawValue)")
            #endif
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                // UIKit remains authoritative on rejection; never rotate buffers alone.
                #if DEBUG
                print("[PicPal rotation] Scene rotation rejected: \(error.localizedDescription)")
                #endif
            }
        }
    }

    func updateCaptureOrientation(interfaceOrientation: UIInterfaceOrientation? = nil) {
        let sceneOrientation = interfaceOrientation ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }?.interfaceOrientation
        let next = sceneOrientation.map { captureOrientation.updated(forInterface: $0) }
            ?? captureOrientation.updated(for: UIDevice.current.orientation)
        guard next != captureOrientation else { return }
        cameraScreen.interrupt()
        cameraScreen.invalidateReferenceGeometry()
        referenceMatchState.reset()
        voiceCoach.stop()
        captureOrientation = next
        #if DEBUG
        print("[PicPal rotation] Applied scene capture=\(next)")
        #endif
        camera.setOrientation(next)
        motionManager.setOrientation(next)
        showEVControls = false
        syncReferenceAnalysis()
    }
}
