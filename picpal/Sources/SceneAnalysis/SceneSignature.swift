import CoreVideo

/// A compact scene fingerprint computed from a camera frame.
/// Used to suppress redundant heavy analysis when the scene hasn't changed.
public struct SceneSignature: Sendable, Equatable {

    /// Mean luminance of a 16×16 downsampled Y-plane (0.0–1.0).
    public let meanLuminance: Double

    /// Variance of luminance over the 16×16 grid (0.0–1.0 approx).
    public let luminanceVariance: Double

    /// Returns `true` when this signature differs materially from `other`.
    ///
    /// Uses named thresholds — no magic numbers.
    public func isMateriallyDifferent(from other: SceneSignature) -> Bool {
        abs(meanLuminance - other.meanLuminance) > SceneSignature.defaultLuminanceDeltaThreshold
            || abs(luminanceVariance - other.luminanceVariance) > SceneSignature.defaultVarianceDeltaThreshold
    }
}

public extension SceneSignature {

    // MARK: - Named thresholds

    static let defaultLuminanceDeltaThreshold: Double = 0.03
    static let defaultVarianceDeltaThreshold: Double  = 0.005
    static let downsampleGridSize: Int = 16

    // MARK: - Factory

    /// Compute a `SceneSignature` from a `CVPixelBuffer` (YCbCr or Grayscale).
    ///
    /// Samples the Y-plane using stride-based iteration (no Accelerate dependency
    /// required — correctness over micro-optimization for now).
    /// Returns `nil` if the pixel buffer cannot be locked or has no Y-plane.
    static func compute(from pixelBuffer: CVPixelBuffer) -> SceneSignature? {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)

        let baseAddress: UnsafeMutableRawPointer?
        let bytesPerRow: Int
        let width: Int
        let height: Int

        if planeCount == 0 {
            // Grayscale — use flat base address
            baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            width  = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        } else {
            // YCbCr — sample Y-plane (plane 0)
            baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            width  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        }

        guard let base = baseAddress, width > 0, height > 0 else { return nil }

        let stepX = max(1, width  / downsampleGridSize)
        let stepY = max(1, height / downsampleGridSize)

        var values = [Double]()
        values.reserveCapacity(downsampleGridSize * downsampleGridSize)

        for row in 0..<downsampleGridSize {
            for col in 0..<downsampleGridSize {
                let offset = (row * stepY * bytesPerRow) + (col * stepX)
                let byte = base.load(fromByteOffset: offset, as: UInt8.self)
                values.append(Double(byte))
            }
        }

        guard !values.isEmpty else { return nil }

        let count  = Double(values.count)
        let mean   = values.reduce(0.0, +) / count
        let variance = values.reduce(0.0) { acc, v in acc + (v - mean) * (v - mean) } / count

        return SceneSignature(
            meanLuminance: mean / 255.0,
            luminanceVariance: variance / (255.0 * 255.0)
        )
    }
}
