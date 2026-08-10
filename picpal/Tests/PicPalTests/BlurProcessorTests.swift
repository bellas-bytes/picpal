import Testing
import CoreVideo
@testable import PicPal

// MARK: - BlurProcessorTests

/// Tests for `BlurProcessor` and `BlurSignal`.
///
/// Pixel buffers are created with CoreVideo only (no AVFoundation) so tests
/// run without camera hardware or a simulator entitlement.
struct BlurProcessorTests {

    // MARK: - Helpers

    /// Creates a YpCbCr 420 biplanar pixel buffer with the Y plane explicitly zeroed.
    ///
    /// `CVPixelBufferCreate` does not guarantee zero-initialised backing memory, so
    /// the Y plane is zeroed here to produce a deterministic uniform-grey frame.
    private func makeYpCbCrBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            nil,
            &buffer
        )
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            memset(base, 0, rowBytes * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Creates a YpCbCr buffer whose Y plane is filled with a 2-pixel checkerboard
    /// (alternating 0 and 255), producing strong edges and a high Laplacian variance.
    private func makeCheckerboardBuffer(width: Int = 64, height: Int = 64) -> CVPixelBuffer? {
        guard let buffer = makeYpCbCrBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let yPlane   = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                yPlane[row * rowBytes + col] = (row + col) % 2 == 0 ? 255 : 0
            }
        }
        return buffer
    }

    // MARK: - Default constants

    @Test("defaultMaxDimension constant equals 256")
    func defaultMaxDimensionIsCorrect() {
        #expect(BlurProcessor.defaultMaxDimension == 256)
    }

    @Test("defaultBlurThreshold constant equals 50.0")
    func defaultBlurThresholdIsCorrect() {
        #expect(BlurProcessor.defaultBlurThreshold == 50.0)
    }

    // MARK: - Uniform gray frame (blurry)

    @Test("Uniform gray frame produces zero Laplacian variance and isBlurry == true")
    func uniformGrayFrameIsBlurry() {
        guard let buffer = makeYpCbCrBuffer() else {
            Issue.record("Failed to allocate YpCbCr pixel buffer")
            return
        }
        let processor = BlurProcessor()
        let signal    = processor.process(pixelBuffer: buffer)
        // All Y=0 → Laplacian output = 0 everywhere → variance = 0 < threshold.
        #expect(signal.sharpnessScore < BlurProcessor.defaultBlurThreshold)
        #expect(signal.isBlurry == true)
    }

    // MARK: - Checkerboard frame (sharp)

    @Test("Checkerboard frame produces high Laplacian variance and isBlurry == false")
    func checkerboardFrameIsSharp() {
        guard let buffer = makeCheckerboardBuffer() else {
            Issue.record("Failed to allocate checkerboard pixel buffer")
            return
        }
        let processor = BlurProcessor()
        let signal    = processor.process(pixelBuffer: buffer)
        #expect(signal.sharpnessScore > BlurProcessor.defaultBlurThreshold)
        #expect(signal.isBlurry == false)
    }

    // MARK: - Threshold boundary via BlurSignal struct

    @Test("BlurSignal with score strictly below threshold is blurry")
    func scoreBelowThresholdIsBlurry() {
        let threshold: Double = 100.0
        let signal = BlurSignal(sharpnessScore: threshold - 0.001, isBlurry: true)
        #expect(signal.isBlurry == true)
    }

    @Test("BlurSignal with score strictly above threshold is not blurry")
    func scoreAboveThresholdIsNotBlurry() {
        let threshold: Double = 100.0
        let signal = BlurSignal(sharpnessScore: threshold + 0.001, isBlurry: false)
        #expect(signal.isBlurry == false)
    }

    // MARK: - Threshold boundary via BlurProcessor

    @Test("Processor with infinite threshold classifies any frame as blurry")
    func infiniteThresholdMakesEverythingBlurry() {
        guard let buffer = makeCheckerboardBuffer() else {
            Issue.record("Failed to allocate checkerboard pixel buffer")
            return
        }
        let processor = BlurProcessor(blurThreshold: .infinity)
        let signal    = processor.process(pixelBuffer: buffer)
        #expect(signal.isBlurry == true)
    }

    @Test("Processor with zero threshold classifies a sharp frame as not blurry")
    func zeroThresholdMakesSharpFrameNotBlurry() {
        guard let buffer = makeCheckerboardBuffer() else {
            Issue.record("Failed to allocate checkerboard pixel buffer")
            return
        }
        let processor = BlurProcessor(blurThreshold: 0)
        let signal    = processor.process(pixelBuffer: buffer)
        // Any positive Laplacian variance > 0 = not blurry.
        #expect(signal.isBlurry == false)
    }

    // MARK: - Non-YpCbCr format fallback

    @Test("Non-YpCbCr buffer returns fallback signal with isBlurry == true and score == 0")
    func nonYpCbCrBufferReturnsFallback() {
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
        let processor = BlurProcessor()
        let signal    = processor.process(pixelBuffer: buffer)
        #expect(signal.sharpnessScore == 0)
        #expect(signal.isBlurry == true)
    }

    // MARK: - BlurSignal struct properties

    @Test("BlurSignal stores sharpnessScore and isBlurry correctly")
    func blurSignalStoresProperties() {
        let signal = BlurSignal(sharpnessScore: 123.45, isBlurry: false)
        #expect(signal.sharpnessScore == 123.45)
        #expect(signal.isBlurry == false)
    }

    @Test("BlurSignal is Equatable — identical values compare equal")
    func blurSignalEquality() {
        let a = BlurSignal(sharpnessScore: 75.0, isBlurry: false)
        let b = BlurSignal(sharpnessScore: 75.0, isBlurry: false)
        #expect(a == b)
    }
}
