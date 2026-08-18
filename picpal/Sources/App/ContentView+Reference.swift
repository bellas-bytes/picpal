import SwiftUI

// MARK: - Named constants

/// Number of consecutive within-threshold frames required to confirm a match.
/// Exposed as `internal` so ReferenceIntegrationTests can use the same constant.
internal let referenceMatchConfirmationFrames: Int = 8

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
        vlmOrchestrator?.referenceImage = nil
        vlmOrchestrator?.referenceModeConsented = false
    }

    // MARK: - Per-frame coaching callback

    /// Returns a `@Sendable` callback suitable for injection into `wireUp()`'s
    /// `SignalFrameAccumulator`.
    ///
    /// The callback dispatches a `Task { @MainActor }` on every frame so that:
    /// - `ReferenceSession.pose` (a `@MainActor @Published` property) is accessed safely.
    /// - `ReferenceMatchState` (a `@MainActor ObservableObject`) is mutated safely.
    /// - SwiftUI automatically re-renders `ReferenceOverlayView` when `isMatched` changes.
    ///
    /// Match logic:
    /// - Increment `count` while the delta is within threshold; reset to 0 when outside.
    /// - Set `isMatched = true` once `count` reaches `referenceMatchConfirmationFrames`.
    /// - Pass `isNewMatchEvent` (a one-frame transition flag) to `ReferenceCoach` so the
    ///   "nice — that looks like the reference shot" cue fires exactly once per match event.
    func makeReferenceCoachingCallback(
        coach: VoiceCoach,
        matchState: ReferenceMatchState,
        sessionHandle: ReferenceSessionHandle
    ) -> @Sendable (SignalFrame) -> Void {
        return { [weak matchState, sessionHandle, coach] frame in
            Task { @MainActor [weak matchState, sessionHandle, coach] in
                guard let ms = matchState,
                      let session = sessionHandle.session,
                      let pose = session.pose else { return }

                guard let body = frame.body, body.dominantRect != nil else {
                    ms.count = 0
                    ms.isMatched = false
                    return
                }
                let delta = computePoseDelta(referencePose: pose, liveLandmarks: body)

                if delta.isWithinThreshold {
                    ms.count += 1
                } else {
                    ms.count = 0
                    ms.isMatched = false
                }

                // Capture state before the potential transition so isNewMatchEvent
                // is true only on the FIRST frame that crosses the threshold.
                let wasMatched = ms.isMatched
                if ms.count >= referenceMatchConfirmationFrames && !ms.isMatched {
                    ms.isMatched = true
                }
                let isNewMatchEvent = !wasMatched && ms.isMatched

                if let cue = ReferenceCoach().cue(from: delta, isNewMatch: isNewMatchEvent) {
                    coach.speak(cue)
                }
            }
        }
    }
}
