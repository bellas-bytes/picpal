import CoreVideo

// MARK: - ExposureProcessor

/// Pure, side-effect-free computation from a `CVPixelBuffer` to an `ExposureSignal`.
///
/// ## Algorithm
/// 1. Lock the luma (Y) plane of the pixel buffer for read-only access.
/// 2. Sample every `sampleStride`-th pixel in both dimensions for speed.
/// 3. Count pixels at or below `shadowClipThreshold` (crushed blacks) and
///    pixels at or above `highlightClipThreshold` (clipped whites).
/// 4. Compute the fraction of sampled pixels in each category.
/// 5. Classify: if highlight fraction exceeds `overexposedThreshold` → `.overexposed`;
///    else if shadow fraction exceeds `underexposedThreshold` → `.underexposed`;
///    else → `.ok`. Overexposed takes priority when both thresholds are exceeded.
///
/// ## Pixel format
/// Designed for `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`.
/// Plane 0 carries the Y (luma) channel, with video-range values 16–235.
/// Values ≤ 16 are crushed blacks; values ≥ 235 are clipped whites.
/// The configurable thresholds default to 20 and 230 respectively to add
/// a small safety margin around the extremes.
///
/// ## Fallback
/// If the pixel buffer's plane 0 base address is unavailable (e.g., wrong format
/// in tests), the processor returns a neutral `ExposureSignal` with fractions
/// `0.0` and level `.ok`.
public struct ExposureProcessor: Sendable {

    // MARK: - Default constants

    /// Stride used when sampling the luma plane in both dimensions.
    public static let defaultSampleStride: Int = 4

    /// Luma values at or below this are counted as shadow-clipped.
    public static let defaultShadowClipThreshold: UInt8 = 20

    /// Luma values at or above this are counted as highlight-clipped.
    public static let defaultHighlightClipThreshold: UInt8 = 230

    /// Shadow-clip fraction above which the frame is classified as underexposed.
    public static let defaultUnderexposedThreshold: Double = 0.15

    /// Highlight-clip fraction above which the frame is classified as overexposed.
    public static let defaultOverexposedThreshold: Double = 0.10

    // MARK: - Properties

    public let sampleStride: Int
    public let shadowClipThreshold: UInt8
    public let highlightClipThreshold: UInt8
    public let underexposedThreshold: Double
    public let overexposedThreshold: Double

    // MARK: - Init

    public init(
        sampleStride: Int = ExposureProcessor.defaultSampleStride,
        shadowClipThreshold: UInt8 = ExposureProcessor.defaultShadowClipThreshold,
        highlightClipThreshold: UInt8 = ExposureProcessor.defaultHighlightClipThreshold,
        underexposedThreshold: Double = ExposureProcessor.defaultUnderexposedThreshold,
        overexposedThreshold: Double = ExposureProcessor.defaultOverexposedThreshold
    ) {
        self.sampleStride = sampleStride
        self.shadowClipThreshold = shadowClipThreshold
        self.highlightClipThreshold = highlightClipThreshold
        self.underexposedThreshold = underexposedThreshold
        self.overexposedThreshold = overexposedThreshold
    }

    // MARK: - Processing

    /// Computes an `ExposureSignal` from the luma plane of `pixelBuffer`.
    public func process(pixelBuffer: CVPixelBuffer) -> ExposureSignal {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .ok)
        }

        let width    = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height   = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let yPlane   = baseAddress.assumingMemoryBound(to: UInt8.self)

        var shadowCount    = 0
        var highlightCount = 0
        var totalCount     = 0

        var row = 0
        while row < height {
            var col = 0
            while col < width {
                let luma = yPlane[row * rowBytes + col]
                if luma <= shadowClipThreshold {
                    shadowCount += 1
                } else if luma >= highlightClipThreshold {
                    highlightCount += 1
                }
                totalCount += 1
                col += sampleStride
            }
            row += sampleStride
        }

        guard totalCount > 0 else {
            return ExposureSignal(shadowClipFraction: 0, highlightClipFraction: 0, level: .ok)
        }

        let shadowFraction    = Double(shadowCount) / Double(totalCount)
        let highlightFraction = Double(highlightCount) / Double(totalCount)
        let level             = classify(shadow: shadowFraction, highlight: highlightFraction)

        return ExposureSignal(
            shadowClipFraction: shadowFraction,
            highlightClipFraction: highlightFraction,
            level: level
        )
    }

    // MARK: - Private helpers

    /// Derives the exposure level; overexposed takes priority when both clip
    /// fractions exceed their respective thresholds.
    private func classify(shadow: Double, highlight: Double) -> ExposureLevel {
        if highlight > overexposedThreshold {
            return .overexposed
        }
        if shadow > underexposedThreshold {
            return .underexposed
        }
        return .ok
    }
}
