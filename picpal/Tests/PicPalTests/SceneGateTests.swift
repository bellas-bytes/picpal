import CoreVideo
import Testing
@testable import PicPal

// MARK: - Helpers

/// Creates a solid-luminance YCbCr 4:2:0 pixel buffer for testing.
///
/// Every Y-plane sample is set to `y`, producing a uniform-luminance frame.
private func makeSolidYBuffer(width: Int = 64, height: Int = 64, y: UInt8) -> CVPixelBuffer? {
    var buf: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        nil, &buf)
    guard let buf else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    if let base = CVPixelBufferGetBaseAddressOfPlane(buf, 0) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        for row in 0..<height {
            memset(base.advanced(by: row * stride), Int32(y), width)
        }
    }
    return buf
}

// MARK: - SceneSignature Tests

struct SceneSignatureTests {

    // Test 1: Large luminance delta is materially different
    @Test("Large luminance delta is materially different")
    func largeLuminanceDeltaIsMateriallyDifferent() {
        let low  = SceneSignature(meanLuminance: 0.10, luminanceVariance: 0.001)
        let high = SceneSignature(meanLuminance: 0.50, luminanceVariance: 0.001)
        #expect(low.isMateriallyDifferent(from: high))
    }

    // Test 2: Small luminance delta is NOT materially different
    @Test("Small luminance delta is not materially different")
    func smallLuminanceDeltaIsNotDifferent() {
        let a = SceneSignature(meanLuminance: 0.50, luminanceVariance: 0.001)
        let b = SceneSignature(meanLuminance: 0.515, luminanceVariance: 0.001)  // delta = 0.015 < 0.03
        #expect(!a.isMateriallyDifferent(from: b))
    }

    // Test 3: Large variance delta is materially different
    @Test("Large variance delta is materially different")
    func largeVarianceDeltaIsMateriallyDifferent() {
        let flat    = SceneSignature(meanLuminance: 0.50, luminanceVariance: 0.001)
        let complex = SceneSignature(meanLuminance: 0.50, luminanceVariance: 0.020)  // delta = 0.019 > 0.005
        #expect(flat.isMateriallyDifferent(from: complex))
    }

    // Test 4: Thresholds have expected values
    @Test("Named thresholds have expected values")
    func namedThresholdsAreCorrect() {
        #expect(SceneSignature.defaultLuminanceDeltaThreshold == 0.03)
        #expect(SceneSignature.defaultVarianceDeltaThreshold  == 0.005)
        #expect(SceneSignature.downsampleGridSize == 16)
    }

    // Test 5: compute returns non-nil for a valid YCbCr buffer
    @Test("SceneSignature.compute returns non-nil for valid YCbCr buffer")
    func computeReturnsNonNilForYCbCr() {
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        let sig = SceneSignature.compute(from: buf)
        #expect(sig != nil)
    }

    // Test 6: Uniform dark buffer has low mean luminance
    @Test("Uniform dark buffer produces low meanLuminance")
    func uniformDarkBufferHasLowLuminance() {
        guard let buf = makeSolidYBuffer(y: 0) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        let sig = SceneSignature.compute(from: buf)
        #expect(sig != nil)
        if let sig {
            #expect(sig.meanLuminance < 0.01)
        }
    }

    // Test 7: Uniform bright buffer has high mean luminance
    @Test("Uniform bright buffer produces high meanLuminance")
    func uniformBrightBufferHasHighLuminance() {
        guard let buf = makeSolidYBuffer(y: 235) else {  // 235 = video range max
            Issue.record("Failed to create pixel buffer")
            return
        }
        let sig = SceneSignature.compute(from: buf)
        #expect(sig != nil)
        if let sig {
            #expect(sig.meanLuminance > 0.80)
        }
    }

    // Test 8: Uniform buffer has near-zero variance
    @Test("Uniform buffer produces near-zero variance")
    func uniformBufferHasNearZeroVariance() {
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        let sig = SceneSignature.compute(from: buf)
        #expect(sig != nil)
        if let sig {
            #expect(sig.luminanceVariance < 0.0001)
        }
    }
}

// MARK: - SceneGate Tests

struct SceneGateTests {

    // Test 1 (Gate): SceneGate blocks frames when not settled
    @Test("SceneGate blocks frames when not settled")
    func blocksFramesWhenNotSettled() {
        let gate = SceneGate()  // default settleRequired = true, isSettled = false
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        #expect(!gate.shouldProcess(pixelBuffer: buf))
    }

    // Test 2 (Gate): SceneGate passes first frame when settled
    @Test("SceneGate passes first frame when settled")
    func passesFirstFrameWhenSettled() {
        let gate = SceneGate()
        gate.update(isSettled: true)
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        #expect(gate.shouldProcess(pixelBuffer: buf))
    }

    // Test 3 (Gate): SceneGate blocks duplicate frame when scene unchanged
    @Test("SceneGate blocks duplicate frame when scene unchanged")
    func blocksDuplicateFrameWhenUnchanged() {
        let gate = SceneGate()
        gate.update(isSettled: true)
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        // First call stores signature and passes
        let first = gate.shouldProcess(pixelBuffer: buf)
        #expect(first)
        // Second call with same buffer — same signature — should be blocked
        let second = gate.shouldProcess(pixelBuffer: buf)
        #expect(!second)
    }

    // Test 4 (Gate): SceneGate passes materially changed frame
    @Test("SceneGate passes materially changed frame")
    func passesMateriallyChangedFrame() {
        let gate = SceneGate()
        gate.update(isSettled: true)
        guard let dark = makeSolidYBuffer(y: 0),
              let bright = makeSolidYBuffer(y: 200) else {
            Issue.record("Failed to create pixel buffers")
            return
        }
        let first = gate.shouldProcess(pixelBuffer: dark)
        #expect(first)
        // Bright buffer has materially different luminance
        let second = gate.shouldProcess(pixelBuffer: bright)
        #expect(second)
    }

    // Test 5 (Gate): lastProcessedSignature is nil before any frame
    @Test("lastProcessedSignature is nil before any frame")
    func lastSignatureNilInitially() {
        let gate = SceneGate()
        #expect(gate.lastProcessedSignature == nil)
    }

    // Test 6 (Gate): lastProcessedSignature is set after first passed frame
    @Test("lastProcessedSignature is set after first passed frame")
    func lastSignatureSetAfterFirstFrame() {
        let gate = SceneGate()
        gate.update(isSettled: true)
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        _ = gate.shouldProcess(pixelBuffer: buf)
        #expect(gate.lastProcessedSignature != nil)
    }

    // Test 7 (Gate): settleRequired:false bypasses settle gate
    @Test("settleRequired false bypasses settle gate")
    func settleRequiredFalseBypassesGate() {
        let gate = SceneGate(settleRequired: false)
        // Do NOT call update(isSettled:) — gate starts unsettled
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        // Should pass because settleRequired is false
        #expect(gate.shouldProcess(pixelBuffer: buf))
    }

    // Test 8 (Gate): SceneGate.defaultSettleRequired is true
    @Test("defaultSettleRequired is true")
    func defaultSettleRequiredIsTrue() {
        #expect(SceneGate.defaultSettleRequired == true)
    }

    // Test 9 (Gate): lastProcessedSignature updates on each passed frame
    @Test("lastProcessedSignature updates when a new scene passes")
    func lastSignatureUpdatesOnNewScene() {
        let gate = SceneGate()
        gate.update(isSettled: true)
        guard let dark = makeSolidYBuffer(y: 0),
              let bright = makeSolidYBuffer(y: 200) else {
            Issue.record("Failed to create pixel buffers")
            return
        }
        _ = gate.shouldProcess(pixelBuffer: dark)
        let firstSig = gate.lastProcessedSignature

        _ = gate.shouldProcess(pixelBuffer: bright)
        let secondSig = gate.lastProcessedSignature

        #expect(firstSig != secondSig)
    }

    // Test 10 (Gate): blocked frames do not update lastProcessedSignature
    @Test("Blocked duplicate frame does not update lastProcessedSignature")
    func blockedFrameDoesNotUpdateSignature() {
        let gate = SceneGate()
        gate.update(isSettled: true)
        guard let buf = makeSolidYBuffer(y: 128) else {
            Issue.record("Failed to create pixel buffer")
            return
        }
        _ = gate.shouldProcess(pixelBuffer: buf)
        let sig1 = gate.lastProcessedSignature

        // Duplicate — should be blocked, signature should be unchanged
        _ = gate.shouldProcess(pixelBuffer: buf)
        let sig2 = gate.lastProcessedSignature

        #expect(sig1 == sig2)
    }
}
