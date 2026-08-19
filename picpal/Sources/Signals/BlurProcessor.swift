import Accelerate
import CoreVideo

/// Pure Laplacian-variance sharpness estimator.
///
/// Extracts the Y (luma) plane from a YpCbCr pixel buffer, optionally
/// downscales it to `maxDimension × maxDimension` using `vImageScale_Planar8`,
/// applies a 3×3 discrete Laplacian kernel via `vImageConvolve_PlanarF`, and
/// computes the variance of the convolution output as the sharpness score.
///
/// ## Thread safety
/// `BlurProcessor` is a `Sendable` value type. `process(pixelBuffer:)` may be
/// called from any thread; it locks the pixel buffer for the duration of the call.
///
/// ## Format requirement
/// Input must be `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`. Any other
/// format yields `BlurSignal(sharpnessScore: 0, isBlurry: true)`.
public struct BlurProcessor: Sendable {

    // MARK: - Public constants

    /// Default maximum side-length (pixels) of the luma plane before downscaling.
    public static let defaultMaxDimension: Int = 256

    /// Default sharpness score threshold below which a frame is classified as blurry.
    public static let defaultBlurThreshold: Double = 50.0

    // MARK: - Private constants

    private enum Kernel {
        /// 3×3 discrete Laplacian: [0,1,0; 1,-4,1; 0,1,0].
        static let values: [Float] = [
             0,  1,  0,
             1, -4,  1,
             0,  1,  0
        ]
        static let size: UInt32 = 3
        static let backgroundColor: Float = 0.0
    }

    private enum Format {
        static let ypCbCr420VideoRange: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        static let yPlaneIndex: Int = 0
        static let minimumPlaneCount: Int = 1
        /// Float upper-bound for Planar8→PlanarF conversion that preserves the [0,255] scale.
        static let floatScale: Float = 255.0
    }

    // MARK: - Configuration

    /// Maximum side length of the luma plane before downscaling (default: 256 px).
    public let maxDimension: Int

    /// Sharpness score below which a frame is classified as blurry (default: 50.0).
    public let blurThreshold: Double

    // MARK: - Init

    /// Creates a `BlurProcessor` with the given configuration.
    ///
    /// - Parameters:
    ///   - maxDimension: Downscale the luma plane when either dimension exceeds this value.
    ///   - blurThreshold: Score threshold for the `isBlurry` classification.
    public init(
        maxDimension: Int = BlurProcessor.defaultMaxDimension,
        blurThreshold: Double = BlurProcessor.defaultBlurThreshold
    ) {
        self.maxDimension  = maxDimension
        self.blurThreshold = blurThreshold
    }

    // MARK: - Public API

    /// Compute a `BlurSignal` from a pixel buffer. Safe to call from any thread.
    ///
    /// Returns `BlurSignal(sharpnessScore: 0, isBlurry: true)` on format mismatch
    /// or internal allocation failure.
    ///
    /// - Parameter pixelBuffer: A camera frame; must be YpCbCr biplanar format.
    public func process(pixelBuffer: CVPixelBuffer) -> BlurSignal {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard isValidFormat(pixelBuffer),
              let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, Format.yPlaneIndex)
        else {
            return BlurSignal(sharpnessScore: 0, isBlurry: true)
        }

        let srcWidth    = CVPixelBufferGetWidthOfPlane(pixelBuffer,        Format.yPlaneIndex)
        let srcHeight   = CVPixelBufferGetHeightOfPlane(pixelBuffer,       Format.yPlaneIndex)
        let srcRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer,  Format.yPlaneIndex)

        var srcBuffer = vImage_Buffer(
            data:     baseAddress,
            height:   vImagePixelCount(srcHeight),
            width:    vImagePixelCount(srcWidth),
            rowBytes: srcRowBytes
        )

        let score: Double
        if srcWidth > maxDimension || srcHeight > maxDimension {
            score = downscaleAndCompute(src: &srcBuffer, srcWidth: srcWidth, srcHeight: srcHeight)
        } else {
            score = computeLaplacianVariance(src: &srcBuffer, width: srcWidth, height: srcHeight)
        }

        return BlurSignal(sharpnessScore: score, isBlurry: score < blurThreshold)
    }

    // MARK: - Private: format check

    private func isValidFormat(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let format      = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planeCount  = CVPixelBufferGetPlaneCount(pixelBuffer)
        return format     == Format.ypCbCr420VideoRange
            && planeCount >= Format.minimumPlaneCount
    }

    // MARK: - Private: downscale

    private func downscaleAndCompute(
        src: inout vImage_Buffer,
        srcWidth: Int,
        srcHeight: Int
    ) -> Double {
        let scale     = Double(maxDimension) / Double(max(srcWidth, srcHeight))
        let dstWidth  = max(1, Int(Double(srcWidth)  * scale))
        let dstHeight = max(1, Int(Double(srcHeight) * scale))
        let byteCount = dstWidth * dstHeight

        guard let rawData = malloc(byteCount) else { return 0 }
        defer { free(rawData) }

        var dstBuffer = vImage_Buffer(
            data:     rawData,
            height:   vImagePixelCount(dstHeight),
            width:    vImagePixelCount(dstWidth),
            rowBytes: dstWidth
        )

        let err = vImageScale_Planar8(&src, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else { return 0 }

        return computeLaplacianVariance(src: &dstBuffer, width: dstWidth, height: dstHeight)
    }

    // MARK: - Private: Laplacian variance

    private func computeLaplacianVariance(
        src: inout vImage_Buffer,
        width: Int,
        height: Int
    ) -> Double {
        let pixelCount  = width * height
        let floatStride = MemoryLayout<Float>.stride

        // Convert Planar8 → PlanarF preserving the [0, 255] value range so that the
        // resulting Laplacian variance is in the same scale as the blurThreshold constant
        // (whose typical range is documented in the Laplacian-variance literature for uint8
        // inputs: < 50 = blurry, 50–200 = moderate, > 200 = sharp).
        guard let floatRaw = malloc(pixelCount * floatStride) else { return 0 }
        defer { free(floatRaw) }

        var floatBuffer = vImage_Buffer(
            data:     floatRaw,
            height:   vImagePixelCount(height),
            width:    vImagePixelCount(width),
            rowBytes: width * floatStride
        )

        let convertErr = vImageConvert_Planar8toPlanarF(
            &src, &floatBuffer,
            Format.floatScale, 0.0,     // map [0, 255] uint8 → [0.0, 255.0] float
            vImage_Flags(kvImageNoFlags)
        )
        guard convertErr == kvImageNoError else { return 0 }

        // Apply 3×3 Laplacian kernel.
        guard let convRaw = malloc(pixelCount * floatStride) else { return 0 }
        defer { free(convRaw) }

        var convBuffer = vImage_Buffer(
            data:     convRaw,
            height:   vImagePixelCount(height),
            width:    vImagePixelCount(width),
            rowBytes: width * floatStride
        )

        let convErr = Kernel.values.withUnsafeBufferPointer { kernelPtr in
            vImageConvolve_PlanarF(
                &floatBuffer, &convBuffer,
                nil,
                0, 0,
                kernelPtr.baseAddress!,
                Kernel.size, Kernel.size,
                Kernel.backgroundColor,
                vImage_Flags(kvImageEdgeExtend)
            )
        }
        guard convErr == kvImageNoError else { return 0 }

        let floatPtr = convRaw.assumingMemoryBound(to: Float.self)
        return laplacianVariance(floatPtr, count: pixelCount)
    }

    // MARK: - Private: variance computation

    private func laplacianVariance(_ values: UnsafePointer<Float>, count: Int) -> Double {
        guard count > 0 else { return 0 }
        var sum: Double = 0
        for i in 0..<count { sum += Double(values[i]) }
        let mean = sum / Double(count)
        var sumSq: Double = 0
        for i in 0..<count {
            let diff = Double(values[i]) - mean
            sumSq += diff * diff
        }
        return sumSq / Double(count)
    }
}
