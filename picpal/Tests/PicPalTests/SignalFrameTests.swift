import Foundation
import Testing
@testable import PicPal

// MARK: - SignalFrameTests

/// Tests for `SignalFrame` construction, default values, and extensibility contracts.
struct SignalFrameTests {

    // MARK: - Static empty

    @Test("SignalFrame.empty has timestamp zero and all signals nil")
    func emptyHasNilSignals() {
        let frame = SignalFrame.empty
        #expect(frame.timestamp == 0)
        #expect(frame.tilt == nil)
        #expect(frame.blur == nil)
        #expect(frame.exposure == nil)
        #expect(frame.framing == nil)
    }

    // MARK: - Memberwise init

    @Test("Memberwise init stores all supplied values")
    func memberwiseInitStoresValues() {
        let tilt = TiltSignal(angleDegrees: 3.5, isLevel: false)
        let frame = SignalFrame(timestamp: 42.0, tilt: tilt)
        #expect(frame.timestamp == 42.0)
        #expect(frame.tilt == tilt)
        #expect(frame.blur == nil)
        #expect(frame.exposure == nil)
        #expect(frame.framing == nil)
    }

    @Test("Memberwise init with all fields supplied stores every value")
    func memberwiseInitAllFields() {
        let tilt = TiltSignal(angleDegrees: -1.2, isLevel: true)
        let blur = BlurSignal(sharpnessScore: 120.0, isBlurry: false)
        let exposure = ExposureSignal(shadowClipFraction: 0.0, highlightClipFraction: 0.0, level: .ok)
        let framing = FramingSignal(subjectBox: nil, hint: .noSubject)
        let frame = SignalFrame(
            timestamp: 99.9,
            tilt: tilt,
            blur: blur,
            exposure: exposure,
            framing: framing
        )
        #expect(frame.timestamp == 99.9)
        #expect(frame.tilt == tilt)
        #expect(frame.blur == blur)
        #expect(frame.exposure == exposure)
        #expect(frame.framing == framing)
    }

    // MARK: - Convenience tilt-only init

    @Test("Tilt-only init leaves other signal fields nil")
    func tiltOnlyInitLeavesOtherFieldsNil() {
        let tilt = TiltSignal(angleDegrees: 0.0, isLevel: true)
        let frame = SignalFrame(timestamp: 1.0, tilt: tilt)
        #expect(frame.tilt != nil)
        #expect(frame.blur == nil)
        #expect(frame.exposure == nil)
        #expect(frame.framing == nil)
    }

    // MARK: - Timestamp passthrough

    @Test("Timestamp is preserved exactly by the initialiser")
    func timestampIsPreserved() {
        let timestamp: TimeInterval = 12345.6789
        let frame = SignalFrame(timestamp: timestamp)
        #expect(frame.timestamp == timestamp)
    }
}
