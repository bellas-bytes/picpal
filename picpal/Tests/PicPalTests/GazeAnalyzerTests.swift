import CoreGraphics
import os
import Testing
@testable import PicPal

// MARK: - Thread-safe signal log

private final class GazeSignalLog: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<[BodySignal]>

    init() { lock = OSAllocatedUnfairLock(initialState: []) }

    func record(_ signal: BodySignal) { lock.withLock { $0.append(signal) } }

    var count: Int { lock.withLock { $0.count } }
    var last: BodySignal? { lock.withLock { $0.last } }
}

// MARK: - Fixtures

private enum Fixture {
    static let highConfidence: Float = 0.90
    // Below the 0.5 confidence floor — any landmark using this must be rejected.
    static let lowConfidence: Float = 0.30

    // Reference landmark positions (UIKit-normalised, 0–1 range, top-left origin).
    static let leftTemporalX:  Double = 0.2
    static let rightTemporalX: Double = 0.8
    static let faceY:          Double = 0.5

    // Derived geometry values.
    static var faceMidX:   Double { (leftTemporalX + rightTemporalX) / 2.0 }  // 0.5
    static var faceWidthX: Double { rightTemporalX - leftTemporalX }           // 0.6

    // Yaw threshold from the analyzer constant.
    static let yawThreshold: Double = GazeAnalyzer.defaultYawThreshold        // 0.15

    // Nose-tip X positions relative to the face geometry above.
    // offset at threshold = 0.15 * 0.6 = 0.09 → nose.x = 0.59
    static var noseAtMidline:                Double { faceMidX }
    static var noseAtThresholdRight:         Double { faceMidX + yawThreshold * faceWidthX }
    static var noseJustBeyondThresholdRight: Double { faceMidX + yawThreshold * faceWidthX + 0.001 }
    static var noseClearlyBeyondRight:       Double { faceMidX + 0.30 * faceWidthX }
    static var noseClearlyBeyondLeft:        Double { faceMidX - 0.30 * faceWidthX }

    // Producer tests use a smaller stable-frame count for speed.
    static let stableFrameCount: Int = 2

    // MediaPipe 478-point face mesh: reference landmark indices.
    static let noseTipIndex:        Int = 4
    static let leftTemporalIndex:   Int = 234
    static let rightTemporalIndex:  Int = 454
}

// MARK: - Test helpers

/// Build a `Keypoint` for the left temporal landmark.
private func leftTemporal(confidence: Float = Fixture.highConfidence) -> Keypoint {
    Keypoint(point: CGPoint(x: Fixture.leftTemporalX, y: Fixture.faceY), confidence: confidence)
}

/// Build a `Keypoint` for the right temporal landmark.
private func rightTemporal(confidence: Float = Fixture.highConfidence) -> Keypoint {
    Keypoint(point: CGPoint(x: Fixture.rightTemporalX, y: Fixture.faceY), confidence: confidence)
}

/// Build a `Keypoint` for the nose tip at a given X position.
private func noseTip(x: Double, confidence: Float = Fixture.highConfidence) -> Keypoint {
    Keypoint(point: CGPoint(x: x, y: Fixture.faceY), confidence: confidence)
}

/// Build a full 478-element face-landmark array suitable for `analyze(faceLandmarks:)`.
///
/// Non-reference slots are filled with a neutral centre keypoint. The three
/// reference landmarks (nose tip, left temporal, right temporal) are set from
/// the provided arguments.
private func makeFaceLandmarks(
    noseTipX: Double,
    leftTemporalX: Double = Fixture.leftTemporalX,
    rightTemporalX: Double = Fixture.rightTemporalX,
    confidence: Float = Fixture.highConfidence
) -> [Keypoint] {
    let neutral = Keypoint(point: CGPoint(x: 0.5, y: 0.5), confidence: confidence)
    var landmarks = [Keypoint](repeating: neutral, count: 478)
    landmarks[Fixture.noseTipIndex] = Keypoint(
        point: CGPoint(x: noseTipX, y: Fixture.faceY),
        confidence: confidence
    )
    landmarks[Fixture.leftTemporalIndex] = Keypoint(
        point: CGPoint(x: leftTemporalX, y: Fixture.faceY),
        confidence: confidence
    )
    landmarks[Fixture.rightTemporalIndex] = Keypoint(
        point: CGPoint(x: rightTemporalX, y: Fixture.faceY),
        confidence: confidence
    )
    return landmarks
}

// MARK: - GazeAnalyzerTests

/// Swift Testing suite for `GazeAnalyzer` geometry logic and
/// `GazeSignalProducer` integration via direct keypoint injection.
///
/// Geometry tests call `analyzeKeypoints(leftTemporal:rightTemporal:noseTip:)`
/// directly with synthetic `Keypoint` values — no MediaPipe framework types are
/// constructed. Integration tests call `analyze(faceLandmarks:)` and
/// `GazeSignalProducer.process(faceLandmarks:)` end-to-end.
struct GazeAnalyzerTests {

    private let analyzer = GazeAnalyzer()

    // MARK: - 1. Symmetric face (nose at midline) → goodBody

    @Test("Symmetric face with nose at midline → goodBody")
    func symmetricFaceAtMidlineIsGoodBody() {
        let result = analyzer.analyzeKeypoints(
            leftTemporal: leftTemporal(),
            rightTemporal: rightTemporal(),
            noseTip: noseTip(x: Fixture.noseAtMidline)
        )
        #expect(result?.hint == .goodBody)
    }

    // MARK: - 2. Face turned left beyond threshold → gazeAway

    @Test("Face turned left clearly beyond yaw threshold → gazeAway")
    func faceTurnedLeftBeyondThresholdIsGazeAway() {
        let result = analyzer.analyzeKeypoints(
            leftTemporal: leftTemporal(),
            rightTemporal: rightTemporal(),
            noseTip: noseTip(x: Fixture.noseClearlyBeyondLeft)
        )
        #expect(result?.hint == .gazeAway)
    }

    // MARK: - 3. Face turned right beyond threshold → gazeAway

    @Test("Face turned right clearly beyond yaw threshold → gazeAway")
    func faceTurnedRightBeyondThresholdIsGazeAway() {
        let result = analyzer.analyzeKeypoints(
            leftTemporal: leftTemporal(),
            rightTemporal: rightTemporal(),
            noseTip: noseTip(x: Fixture.noseClearlyBeyondRight)
        )
        #expect(result?.hint == .gazeAway)
    }

    // MARK: - 4. Face at exactly threshold → goodBody (boundary: > not >=)

    @Test("Nose exactly at yaw threshold → goodBody (strict > boundary)")
    func noseExactlyAtThresholdIsGoodBody() {
        // yawFraction == yawThreshold exactly: abs(yawFraction) > threshold is false.
        let result = analyzer.analyzeKeypoints(
            leftTemporal: leftTemporal(),
            rightTemporal: rightTemporal(),
            noseTip: noseTip(x: Fixture.noseAtThresholdRight)
        )
        #expect(result?.hint == .goodBody)
    }

    // MARK: - 5. Face just beyond threshold → gazeAway

    @Test("Nose just past yaw threshold (threshold + 0.001 in normalised offset) → gazeAway")
    func noseJustBeyondThresholdIsGazeAway() {
        let result = analyzer.analyzeKeypoints(
            leftTemporal: leftTemporal(),
            rightTemporal: rightTemporal(),
            noseTip: noseTip(x: Fixture.noseJustBeyondThresholdRight)
        )
        #expect(result?.hint == .gazeAway)
    }

    // MARK: - 6. Low-confidence landmark (below floor) → nil

    @Test("Any reference landmark below confidence floor → nil")
    func lowConfidenceNoseTipReturnsNil() {
        let result = analyzer.analyzeKeypoints(
            leftTemporal: leftTemporal(),
            rightTemporal: rightTemporal(),
            noseTip: noseTip(x: Fixture.noseAtMidline, confidence: Fixture.lowConfidence)
        )
        #expect(result == nil)
    }

    // MARK: - 7. Empty faceLandmarks array → nil from analyzer

    @Test("Empty faceLandmarks array → nil from analyze(faceLandmarks:)")
    func emptyFaceLandmarksReturnsNil() {
        let result = analyzer.analyze(faceLandmarks: [])
        #expect(result == nil)
    }

    // MARK: - 8. GazeSignalProducer empty faceLandmarks → smoother nil path

    @Test("GazeSignalProducer empty landmarks breaks stability → noPersonPresent")
    func producerEmptyLandmarksFiresNoPersonPresent() {
        let log = GazeSignalLog()
        let producer = GazeSignalProducer(
            stableFrameCount: Fixture.stableFrameCount,
            onSignal: { log.record($0) }
        )
        // Feed stableFrameCount frames of a centred face to confirm stability.
        let landmarks = makeFaceLandmarks(noseTipX: Fixture.noseAtMidline)
        for _ in 0..<Fixture.stableFrameCount {
            producer.process(faceLandmarks: landmarks)
        }
        let countAfterStable = log.count
        // Break stability with an empty array.
        producer.process(faceLandmarks: [])
        #expect(log.count == countAfterStable + 1)
        #expect(log.last == .noPersonPresent)
    }

    // MARK: - 9. Confidence mean is mean of three reference landmarks

    @Test("goodBody confidence equals mean of three reference landmark confidences")
    func goodBodyConfidenceIsMeanOfThreeKeypoints() {
        let c1: Float = 0.80
        let c2: Float = 0.70
        let c3: Float = 0.90
        let left  = Keypoint(point: CGPoint(x: Fixture.leftTemporalX,  y: Fixture.faceY), confidence: c1)
        let right = Keypoint(point: CGPoint(x: Fixture.rightTemporalX, y: Fixture.faceY), confidence: c2)
        let nose  = Keypoint(point: CGPoint(x: Fixture.noseAtMidline,  y: Fixture.faceY), confidence: c3)
        let result = analyzer.analyzeKeypoints(
            leftTemporal: left,
            rightTemporal: right,
            noseTip: nose
        )
        let expectedMean: Float = (c1 + c2 + c3) / 3.0
        #expect(result?.hint == .goodBody)
        if let confidence = result?.confidence {
            #expect(abs(confidence - expectedMean) < 0.001)
        }
    }

    // MARK: - 10. Short array → nil (cannot index right temporal at 454)

    @Test("faceLandmarks array shorter than right temporal index → nil")
    func shortFaceLandmarksArrayReturnsNil() {
        let small = [Keypoint](
            repeating: Keypoint(point: CGPoint(x: 0.5, y: 0.5), confidence: 0.9),
            count: 10
        )
        let result = analyzer.analyze(faceLandmarks: small)
        #expect(result == nil)
    }

    // MARK: - 11. Low-confidence left temporal → nil

    @Test("Low-confidence left temporal below confidence floor → nil")
    func lowConfidenceLeftTemporalReturnsNil() {
        let result = analyzer.analyzeKeypoints(
            leftTemporal: leftTemporal(confidence: Fixture.lowConfidence),
            rightTemporal: rightTemporal(),
            noseTip: noseTip(x: Fixture.noseAtMidline)
        )
        #expect(result == nil)
    }

    // MARK: - 12. analyze(faceLandmarks:) end-to-end: turned face → gazeAway

    @Test("analyze(faceLandmarks:) full-array end-to-end: turned face → gazeAway")
    func analyzeFaceLandmarksEndToEndGazeAway() {
        let landmarks = makeFaceLandmarks(noseTipX: Fixture.noseClearlyBeyondRight)
        let result = analyzer.analyze(faceLandmarks: landmarks)
        #expect(result?.hint == .gazeAway)
    }
}
