import CoreGraphics
import os
import Testing
@testable import PicPal

// MARK: - Thread-safe signal log

private final class HandSignalLog: @unchecked Sendable {
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
    static let lowConfidence: Float = 0.10  // below 0.6 floor — filtered out

    // Geometry: edge proximity thresholds
    static let edgeMargin: Double = HandObstructionAnalyzer.defaultEdgeMargin  // 0.15
    /// Coordinate that places a keypoint well within the edge margin (near top edge).
    static let nearTopEdge: Double = edgeMargin / 2.0                          // 0.075
    /// Coordinate that places a keypoint safely inside the frame on both axes.
    static let safeCenter: Double = 0.50

    // Keypoint count threshold
    static let minKeypoints: Int = HandObstructionAnalyzer.defaultMinObstructingKeypoints  // 3

    // TemporalSmoother frame count used in producer tests.
    static let stableFrameCount: Int = 2
}

// MARK: - Test helpers

/// Build a single `Keypoint` at (x, y) with the given confidence.
private func keypoint(
    x: Double,
    y: Double,
    confidence: Float = Fixture.highConfidence
) -> Keypoint {
    Keypoint(point: CGPoint(x: x, y: y), confidence: confidence)
}

/// Build `count` identical keypoints at (x, y) with the given confidence.
private func keypoints(
    count: Int,
    x: Double,
    y: Double,
    confidence: Float = Fixture.highConfidence
) -> [Keypoint] {
    (0..<count).map { _ in keypoint(x: x, y: y, confidence: confidence) }
}

// MARK: - HandObstructionAnalyzerTests

/// Swift Testing suite for `HandObstructionAnalyzer` geometry logic and
/// `HandObstructionSignalProducer` integration via direct keypoint injection.
///
/// All geometry tests call `analyzeKeypoints(_:)` directly with synthetic
/// `Keypoint` values — no MediaPipe framework types are constructed.
struct HandObstructionAnalyzerTests {

    private let analyzer = HandObstructionAnalyzer()

    // MARK: - 1. 3+ high-confidence near-edge keypoints → lensObstructed

    @Test("Three high-confidence keypoints near top edge → lensObstructed")
    func threeHighConfKeypointsNearTopEdge() {
        let kps = keypoints(count: Fixture.minKeypoints, x: Fixture.safeCenter, y: Fixture.nearTopEdge)
        let result = analyzer.analyzeKeypoints(kps)
        #expect(result?.hint == .lensObstructed)
    }

    // MARK: - 2. 3+ keypoints well inside frame → goodBody

    @Test("Three high-confidence keypoints well inside frame → goodBody")
    func threeHighConfKeypointsWellInside() {
        let kps = keypoints(count: Fixture.minKeypoints, x: Fixture.safeCenter, y: Fixture.safeCenter)
        let result = analyzer.analyzeKeypoints(kps)
        #expect(result?.hint == .goodBody)
    }

    // MARK: - 3. Fewer than minObstructingKeypoints qualifying → nil

    @Test("Fewer than minObstructingKeypoints qualifying keypoints → nil")
    func fewerThanMinQualifyingReturnsNil() {
        // Only minKeypoints - 1 pass the confidence floor.
        let kps = keypoints(
            count: Fixture.minKeypoints - 1,
            x: Fixture.nearTopEdge,
            y: Fixture.nearTopEdge
        )
        let result = analyzer.analyzeKeypoints(kps)
        #expect(result == nil)
    }

    // MARK: - 4. Empty keypoints → nil from analyzer

    @Test("Empty keypoints → nil from analyzer")
    func emptyKeypointsReturnsNil() {
        let result = analyzer.analyzeKeypoints([])
        #expect(result == nil)
    }

    // MARK: - 5. Exactly at threshold near edge → lensObstructed

    @Test("Exactly minObstructingKeypoints near-edge keypoints → lensObstructed")
    func exactlyAtThresholdNearEdge() {
        // Exactly 3 keypoints near the left edge.
        let leftEdgeX = Fixture.nearTopEdge
        let kps = keypoints(count: Fixture.minKeypoints, x: leftEdgeX, y: Fixture.safeCenter)
        let result = analyzer.analyzeKeypoints(kps)
        #expect(result?.hint == .lensObstructed)
    }

    // MARK: - 6. Low-confidence near-edge keypoints not counted

    @Test("Low-confidence near-edge keypoints are excluded from obstruction count")
    func lowConfidenceKeypointsNotCounted() {
        // minKeypoints - 1 high-confidence keypoints near the edge (not enough alone).
        let highConfNearEdge = keypoints(
            count: Fixture.minKeypoints - 1,
            x: Fixture.nearTopEdge,
            y: Fixture.nearTopEdge,
            confidence: Fixture.highConfidence
        )
        // Extra near-edge keypoints below the confidence floor — must be ignored.
        let lowConfNearEdge = keypoints(
            count: Fixture.minKeypoints,
            x: Fixture.nearTopEdge,
            y: Fixture.nearTopEdge,
            confidence: Fixture.lowConfidence
        )
        // Combined: 5 near edge, but only 2 pass the confidence floor → nil.
        let kps = highConfNearEdge + lowConfNearEdge
        let result = analyzer.analyzeKeypoints(kps)
        #expect(result == nil)
    }

    // MARK: - 7. Producer: empty keypoints → smoother nil path fires .noPersonPresent

    @Test("HandObstructionSignalProducer empty keypoints breaks stability → noPersonPresent")
    func producerEmptyKeypointsFiresNoPersonPresent() {
        let log = HandSignalLog()
        let producer = HandObstructionSignalProducer(
            stableFrameCount: Fixture.stableFrameCount,
            onSignal: { log.record($0) }
        )
        // Inject stableFrameCount frames of obstructing keypoints to establish stability.
        let obstructingKps = keypoints(
            count: Fixture.minKeypoints,
            x: Fixture.nearTopEdge,
            y: Fixture.nearTopEdge
        )
        for _ in 0..<Fixture.stableFrameCount {
            producer.process(keypoints: obstructingKps)
        }
        let countAfterStable = log.count
        // Stability confirmed — now break it with empty keypoints.
        producer.process(keypoints: [])
        #expect(log.count == countAfterStable + 1)
        #expect(log.last == .noPersonPresent)
    }

    // MARK: - 8. lensObstructed confidence is mean of obstructing keypoints

    @Test("lensObstructed confidence is the mean of obstructing keypoint confidences")
    func lensObstructedConfidenceIsMeanOfObstructingKeypoints() {
        let c1: Float = 0.80
        let c2: Float = 0.70
        let c3: Float = 1.00
        let kps = [
            keypoint(x: Fixture.nearTopEdge, y: Fixture.nearTopEdge, confidence: c1),
            keypoint(x: Fixture.nearTopEdge, y: Fixture.nearTopEdge, confidence: c2),
            keypoint(x: Fixture.nearTopEdge, y: Fixture.nearTopEdge, confidence: c3),
        ]
        let result = analyzer.analyzeKeypoints(kps)
        let expectedMean = Float((Double(c1) + Double(c2) + Double(c3)) / 3.0)
        #expect(result?.hint == .lensObstructed)
        if let confidence = result?.confidence {
            #expect(abs(confidence - expectedMean) < 0.001)
        }
    }

    // MARK: - 9. Right-edge keypoints also trigger obstruction

    @Test("Three high-confidence keypoints near right edge → lensObstructed")
    func threeHighConfKeypointsNearRightEdge() {
        // Near the right edge: x close to 1.0.
        let nearRightX = 1.0 - Fixture.nearTopEdge
        let kps = keypoints(count: Fixture.minKeypoints, x: nearRightX, y: Fixture.safeCenter)
        let result = analyzer.analyzeKeypoints(kps)
        #expect(result?.hint == .lensObstructed)
    }
}
