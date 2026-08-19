import Testing
import CoreVideo
@testable import PicPal

// MARK: - ExposureProcessorTests

/// Tests for `ExposureProcessor`, `ExposureSignal`, and `ExposureLevel`.
///
/// Pixel buffers are created with CoreVideo only (no AVFoundation) so tests
/// run without camera hardware or a simulator entitlement.
struct ExposureProcessorTests {

    // MARK: - Helpers

    /// Creates a `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` buffer with the Y
    /// plane uniformly filled with `lumaValue`.
    private func makeBuffer(
        width: Int = 64,
        height: Int = 64,
        lumaValue: UInt8
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            memset(base, Int32(lumaValue), rowBytes * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Creates a buffer where the top half of the Y plane is filled with `topValue`
    /// and the bottom half with `bottomValue`.
    private func makeSplitBuffer(
        width: Int = 64,
        height: Int = 64,
        topValue: UInt8,
        bottomValue: UInt8
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let yPlane = base.assumingMemoryBound(to: UInt8.self)
        let midRow = height / 2
        for row in 0..<height {
            let value = row < midRow ? topValue : bottomValue
            for col in 0..<width {
                yPlane[row * rowBytes + col] = value
            }
        }
        return buffer
    }

    // MARK: - Default constants

    @Test("defaultSampleStride constant equals 4")
    func defaultSampleStrideIsCorrect() {
        #expect(ExposureProcessor.defaultSampleStride == 4)
    }

    @Test("defaultShadowClipThreshold constant equals 20")
    func defaultShadowClipThresholdIsCorrect() {
        #expect(ExposureProcessor.defaultShadowClipThreshold == 20)
    }

    @Test("defaultHighlightClipThreshold constant equals 230")
    func defaultHighlightClipThresholdIsCorrect() {
        #expect(ExposureProcessor.defaultHighlightClipThreshold == 230)
    }

    @Test("defaultUnderexposedThreshold constant equals 0.15")
    func defaultUnderexposedThresholdIsCorrect() {
        #expect(ExposureProcessor.defaultUnderexposedThreshold == 0.15)
    }

    @Test("defaultOverexposedThreshold constant equals 0.10")
    func defaultOverexposedThresholdIsCorrect() {
        #expect(ExposureProcessor.defaultOverexposedThreshold == 0.10)
    }

    // MARK: - All-dark buffer → underexposed

    @Test("All-dark luma (value 0) classifies as underexposed")
    func allDarkBufferIsUnderexposed() {
        guard let buffer = makeBuffer(lumaValue: 0) else {
            Issue.record("Failed to allocate dark pixel buffer")
            return
        }
        let processor = ExposureProcessor()
        let signal = processor.process(pixelBuffer: buffer)
        #expect(signal.level == .underexposed)
        #expect(signal.shadowClipFraction > ExposureProcessor.defaultUnderexposedThreshold)
        #expect(signal.highlightClipFraction == 0.0)
    }

    // MARK: - All-bright buffer → overexposed

    @Test("All-bright luma (value 255) classifies as overexposed")
    func allBrightBufferIsOverexposed() {
        guard let buffer = makeBuffer(lumaValue: 255) else {
            Issue.record("Failed to allocate bright pixel buffer")
            return
        }
        let processor = ExposureProcessor()
        let signal = processor.process(pixelBuffer: buffer)
        #expect(signal.level == .overexposed)
        #expect(signal.highlightClipFraction > ExposureProcessor.defaultOverexposedThreshold)
        #expect(signal.shadowClipFraction == 0.0)
    }

    // MARK: - Mid-range buffer → ok

    @Test("Mid-range luma (value 128) classifies as ok")
    func midRangeBufferIsOk() {
        guard let buffer = makeBuffer(lumaValue: 128) else {
            Issue.record("Failed to allocate mid-range pixel buffer")
            return
        }
        let processor = ExposureProcessor()
        let signal = processor.process(pixelBuffer: buffer)
        #expect(signal.level == .ok)
        #expect(signal.shadowClipFraction == 0.0)
        #expect(signal.highlightClipFraction == 0.0)
    }

    // MARK: - Fractions within [0, 1]

    @Test("shadowClipFraction and highlightClipFraction are in [0, 1]")
    func fractionsAreInValidRange() {
        // Test with several different luma values
        let lumaValues: [UInt8] = [0, 20, 128, 230, 255]
        let processor = ExposureProcessor()
        for luma in lumaValues {
            guard let buffer = makeBuffer(lumaValue: luma) else {
                Issue.record("Failed to allocate buffer for luma \(luma)")
                continue
            }
            let signal = processor.process(pixelBuffer: buffer)
            #expect(signal.shadowClipFraction >= 0.0 && signal.shadowClipFraction <= 1.0)
            #expect(signal.highlightClipFraction >= 0.0 && signal.highlightClipFraction <= 1.0)
        }
    }

    // MARK: - Custom thresholds

    @Test("Custom shadow threshold classifies mid-range luma as underexposed")
    func customShadowThresholdClassifiesMidRangeAsUnderexposed() {
        // A processor with shadowClipThreshold = 200 treats luma=128 as shadow-clipped.
        // With underexposedThreshold = 0.01, any non-zero shadow fraction triggers it.
        let processor = ExposureProcessor(
            shadowClipThreshold: 200,
            underexposedThreshold: 0.01
        )
        guard let buffer = makeBuffer(lumaValue: 128) else {
            Issue.record("Failed to allocate pixel buffer")
            return
        }
        let signal = processor.process(pixelBuffer: buffer)
        // luma 128 ≤ 200 (shadow threshold) → all pixels are shadow-clipped → underexposed
        #expect(signal.level == .underexposed)
        #expect(signal.shadowClipFraction > 0.0)
    }

    @Test("Custom highlight threshold classifies mid-range luma as overexposed")
    func customHighlightThresholdClassifiesMidRangeAsOverexposed() {
        // A processor with highlightClipThreshold = 50 treats luma=128 as highlight-clipped.
        // With overexposedThreshold = 0.01, any non-zero highlight fraction triggers it.
        let processor = ExposureProcessor(
            highlightClipThreshold: 50,
            overexposedThreshold: 0.01
        )
        guard let buffer = makeBuffer(lumaValue: 128) else {
            Issue.record("Failed to allocate pixel buffer")
            return
        }
        let signal = processor.process(pixelBuffer: buffer)
        // luma 128 ≥ 50 (highlight threshold) → all pixels are highlight-clipped → overexposed
        #expect(signal.level == .overexposed)
        #expect(signal.highlightClipFraction > 0.0)
    }

    // MARK: - Priority: overexposed wins when both thresholds exceeded

    @Test("Overexposed takes priority when both shadow and highlight fractions exceed thresholds")
    func overexposedTakesPriorityOverUnderexposed() {
        // Top half dark (value 0, shadow-clipped), bottom half bright (value 255,
        // highlight-clipped). With stride 1 both halves contribute equal fractions
        // (~0.5 each), both exceeding their respective thresholds.
        let processor = ExposureProcessor(sampleStride: 1)
        guard let buffer = makeSplitBuffer(topValue: 0, bottomValue: 255) else {
            Issue.record("Failed to allocate split pixel buffer")
            return
        }
        let signal = processor.process(pixelBuffer: buffer)
        // Both fractions exceed their thresholds; overexposed takes priority.
        #expect(signal.shadowClipFraction > ExposureProcessor.defaultUnderexposedThreshold)
        #expect(signal.highlightClipFraction > ExposureProcessor.defaultOverexposedThreshold)
        #expect(signal.level == .overexposed)
    }

    // MARK: - Non-planar buffer fallback

    @Test("Non-planar BGRA buffer returns fallback signal with level ok and zero fractions")
    func nonPlanarBufferReturnsFallback() {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64,
            kCVPixelFormatType_32BGRA,
            nil, &buffer
        )
        guard let buffer else {
            Issue.record("Failed to allocate BGRA pixel buffer")
            return
        }
        let processor = ExposureProcessor()
        let signal = processor.process(pixelBuffer: buffer)
        #expect(signal.shadowClipFraction == 0.0)
        #expect(signal.highlightClipFraction == 0.0)
        #expect(signal.level == .ok)
    }

    // MARK: - ExposureSignal struct

    @Test("ExposureSignal stores all properties correctly")
    func exposureSignalStoresProperties() {
        let signal = ExposureSignal(shadowClipFraction: 0.3, highlightClipFraction: 0.05, level: .underexposed)
        #expect(signal.shadowClipFraction == 0.3)
        #expect(signal.highlightClipFraction == 0.05)
        #expect(signal.level == .underexposed)
    }

    @Test("ExposureSignal is Equatable — identical values compare equal")
    func exposureSignalEquality() {
        let a = ExposureSignal(shadowClipFraction: 0.2, highlightClipFraction: 0.0, level: .underexposed)
        let b = ExposureSignal(shadowClipFraction: 0.2, highlightClipFraction: 0.0, level: .underexposed)
        #expect(a == b)
    }

    // MARK: - ExposureLevel raw values

    @Test("ExposureLevel raw values match expected strings")
    func exposureLevelRawValues() {
        #expect(ExposureLevel.underexposed.rawValue == "underexposed")
        #expect(ExposureLevel.ok.rawValue == "ok")
        #expect(ExposureLevel.overexposed.rawValue == "overexposed")
    }
}
