import CoreGraphics
import os
import Testing
import Vision
@testable import PicPal

// MARK: - Thread-safe signal log

/// Thread-safe log for `BodySignal` values emitted by `BodyPoseSignalProducer`.
private final class SignalLog: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<[BodySignal]>

    init() { lock = OSAllocatedUnfairLock(initialState: []) }

    func record(_ signal: BodySignal) { lock.withLock { $0.append(signal) } }

    var values: [BodySignal] { lock.withLock { $0 } }
    var count: Int { lock.withLock { $0.count } }
    var last: BodySignal? { lock.withLock { $0.last } }
    var isEmpty: Bool { lock.withLock { $0.isEmpty } }
}

// MARK: - Fixtures

private enum Fixture {
    // Confidence values
    static let highConfidence: Float = 0.90
    static let lowConfidence: Float = 0.10   // below the 0.5 floor

    // Frame (normalised 0–1)
    static let unitFrame = CGSize(width: 1, height: 1)

    // Crop detection thresholds (match BodyPoseAnalyzer defaults)
    static let cropMargin: Double = BodyPoseAnalyzer.defaultCropMargin           // 0.05
    static let insideMargin: Double = 0.50                                        // well within frame

    // Headroom thresholds (match BodyPoseAnalyzer defaults)
    static let idealHeadroom: Double = BodyPoseAnalyzer.defaultIdealHeadroomFraction    // 0.10
    static let tolerance: Double = BodyPoseAnalyzer.defaultHeadroomTolerance            // 0.05
    static let lowerBound: Double = idealHeadroom - tolerance                            // 0.05
    static let upperBound: Double = idealHeadroom + tolerance                            // 0.15

    // Concrete Y positions for headroom tests
    // UIKit Y: small value = near top. Too small (< lowerBound) → nudgeUp; too large (> upperBound) → nudgeDown.
    static let headroomTooClose: Double = lowerBound - 0.02                  // 0.03 → nudgeUp
    static let headroomTooFar: Double = upperBound + 0.05                    // 0.20 → nudgeDown
    static let headroomIdeal: Double = idealHeadroom                         // 0.10 → goodBody

    // Concrete Y position for crop tests
    static let croppedY: Double = cropMargin / 2.0                           // 0.025 → inside margin
    static let safeCenterXY: Double = insideMargin                           // 0.50 → safe
}

// MARK: - Helpers

private extension BodyPoseAnalyzerTests {

    /// Builds a keypoint dictionary containing a single joint.
    func singleKeypoint(
        joint: VNHumanBodyPoseObservation.JointName,
        x: Double,
        y: Double,
        confidence: Float = Fixture.highConfidence
    ) -> [VNHumanBodyPoseObservation.JointName: Keypoint] {
        [joint: Keypoint(point: CGPoint(x: x, y: y), confidence: confidence)]
    }
}

// MARK: - BodyPoseAnalyzerTests

/// Swift Testing suite for `BodyPoseAnalyzer` geometry logic and
/// `BodyPoseSignalProducer` integration via `injectSignalForTesting`.
///
/// All geometry tests call `analyzeKeypoints(_:frameSize:)` directly with
/// synthetic `Keypoint` values — no `VNHumanBodyPoseObservation` is constructed.
struct BodyPoseAnalyzerTests {

    private let analyzer = BodyPoseAnalyzer()

    // MARK: - 1. Joint at crop margin → awkwardCrop

    @Test("Joint within cropMargin of top edge returns .awkwardCrop")
    func jointAtCropMarginReturnsAwkwardCrop() {
        let keypoints = singleKeypoint(
            joint: .leftWrist,
            x: Fixture.safeCenterXY,
            y: Fixture.croppedY          // 0.025 < cropMargin (0.05) → cropped
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        #expect(result?.hint == .awkwardCrop)
    }

    // MARK: - 2. Joint well inside frame → no crop

    @Test("Joint at centre of frame does not trigger .awkwardCrop")
    func jointWellInsideFrameDoesNotReturnCrop() {
        let keypoints = singleKeypoint(
            joint: .leftWrist,
            x: Fixture.safeCenterXY,     // 0.50 — well inside all margins
            y: Fixture.safeCenterXY
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        // No crop joint near edge; no head joint → goodBody
        #expect(result?.hint != .awkwardCrop)
    }

    // MARK: - 3. Crop detection skips headroom check

    @Test("Crop signal takes priority over headroom signal")
    func cropDetectionSkipsHeadroomCheck() {
        // A wrist at the top edge → would fire awkwardCrop.
        // A nose far from the top (y=0.20 > upperBound) → would fire nudgeDownHeadroom.
        // Crop must win.
        var keypoints: [VNHumanBodyPoseObservation.JointName: Keypoint] = [:]
        keypoints[.leftWrist] = Keypoint(
            point: CGPoint(x: Fixture.safeCenterXY, y: Fixture.croppedY),
            confidence: Fixture.highConfidence
        )
        keypoints[.nose] = Keypoint(
            point: CGPoint(x: Fixture.safeCenterXY, y: Fixture.headroomTooFar),
            confidence: Fixture.highConfidence
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        #expect(result?.hint == .awkwardCrop)
    }

    // MARK: - 4. Head too close to top → nudgeUpHeadroom

    @Test("Head very close to top edge returns .nudgeUpHeadroom")
    func headTooCloseToTopReturnsNudgeUpHeadroom() {
        let keypoints = singleKeypoint(
            joint: .nose,
            x: Fixture.safeCenterXY,
            y: Fixture.headroomTooClose   // 0.03 < lowerBound (0.05) → too little headroom → nudgeUp
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        // UIKit Y is small → head near top edge → move camera up so subject drops in frame.
        #expect(result?.hint == .nudgeUpHeadroom)
    }

    // MARK: - 5. Head too far from top → nudgeDownHeadroom

    @Test("Head far from top edge returns .nudgeDownHeadroom")
    func headTooFarFromTopReturnsNudgeDownHeadroom() {
        let keypoints = singleKeypoint(
            joint: .nose,
            x: Fixture.safeCenterXY,
            y: Fixture.headroomTooFar     // 0.20 > upperBound (0.15) → too much headroom → nudgeDown
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        // UIKit Y is large → head far from top edge → move camera down.
        #expect(result?.hint == .nudgeDownHeadroom)
    }

    // MARK: - 6. Head in ideal zone → goodBody

    @Test("Head at ideal headroom returns .goodBody")
    func headInIdealZoneReturnsGoodBody() {
        let keypoints = singleKeypoint(
            joint: .nose,
            x: Fixture.safeCenterXY,
            y: Fixture.headroomIdeal      // 0.10 — inside [lowerBound, upperBound]
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        #expect(result?.hint == .goodBody)
    }

    // MARK: - 7. All-low-confidence → nil from analyzer

    @Test("All keypoints below confidence floor returns nil")
    func allLowConfidenceReturnsNil() {
        var keypoints: [VNHumanBodyPoseObservation.JointName: Keypoint] = [:]
        keypoints[.leftWrist] = Keypoint(
            point: CGPoint(x: Fixture.croppedY, y: Fixture.croppedY),
            confidence: Fixture.lowConfidence   // 0.10 < floor (0.50)
        )
        keypoints[.nose] = Keypoint(
            point: CGPoint(x: Fixture.safeCenterXY, y: Fixture.headroomIdeal),
            confidence: Fixture.lowConfidence
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        #expect(result == nil)
    }

    // MARK: - 8. nil observation → smoother receives nil → noPersonPresent

    @Test("nil observation propagates to smoother and fires noPersonPresent after stability break")
    func nilObservationPropagatesToSmoother() {
        let log = SignalLog()
        // stableFrameCount=1: the smoother still requires 2 consecutive equal updates —
        // the "new value" branch initialises the run at count=1 without checking; the
        // second identical update increments to 2 >= 1 and fires. See TemporalSmoother.
        let stableFrameCount = 1
        let producer = BodyPoseSignalProducer(
            stableFrameCount: stableFrameCount,
            onSignal: { log.record($0) }
        )

        let stableSignal = BodySignal(hint: .goodBody, confidence: Fixture.highConfidence, dominantRect: nil)

        // First inject starts the run (runCount=1) but does not fire (new-value branch).
        producer.injectSignalForTesting(stableSignal)
        #expect(log.isEmpty)

        // Second inject with the same signal reaches threshold → fires onSignal.
        producer.injectSignalForTesting(stableSignal)
        #expect(log.count == 1)
        #expect(log.last?.hint == .goodBody)

        // nil observation propagates to smoother → stability breaks → noPersonPresent.
        producer.process(observation: nil)
        #expect(log.count == 2)
        #expect(log.last == .noPersonPresent)
    }

    // MARK: - Bonus: ankle near bottom edge → awkwardCrop

    @Test("Ankle near bottom edge returns .awkwardCrop")
    func ankleNearBottomEdgeReturnsAwkwardCrop() {
        let bottomY = 1.0 - Fixture.cropMargin / 2.0    // 0.975 > 1 - cropMargin (0.95)
        let keypoints = singleKeypoint(
            joint: .leftAnkle,
            x: Fixture.safeCenterXY,
            y: bottomY
        )
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        #expect(result?.hint == .awkwardCrop)
    }

    // MARK: - Bonus: neck used as head proxy when nose absent

    @Test("Neck is used as head proxy when nose is absent")
    func neckUsedAsHeadProxyWhenNoseAbsent() {
        let keypoints = singleKeypoint(
            joint: .neck,
            x: Fixture.safeCenterXY,
            y: Fixture.headroomTooFar    // 0.20 > upperBound → nudgeDown (too much headroom)
        )
        // Note: neck is also a crop-watch joint, but at y=0.20 it is not near any edge.
        let result = analyzer.analyzeKeypoints(keypoints, frameSize: Fixture.unitFrame)
        #expect(result?.hint == .nudgeDownHeadroom)
    }
}
