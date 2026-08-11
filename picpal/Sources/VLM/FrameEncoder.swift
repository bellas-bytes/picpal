import Foundation
import CoreImage
import CoreVideo
import UIKit

// MARK: - FrameEncoder

/// Pure, stateless converter from CVPixelBuffer to downscaled JPEG Data.
///
/// This is the privacy boundary: uncompressed pixel buffers from the camera
/// are downscaled to a fixed maximum dimension and JPEG-compressed before
/// being eligible for transmission to any external service.
///
/// - No I/O, no disk writes, no caching.
/// - Returns `nil` on any unlockable or malformed pixel buffer.
/// - Never crashes on invalid input.
public enum FrameEncoder {

    // MARK: - Named constants

    /// Maximum extent of the longest edge after downscaling (pixels).
    /// A 4K input (3840×2160) scales to at most 512×288 or 288×512.
    public static let maxDimension: Int = 512

    /// JPEG compression quality (0.0–1.0).
    /// 0.75 is a balance between size and perceptual quality for VLM analysis.
    public static let jpegQuality: CGFloat = 0.75

    // MARK: - Public API

    /// Downscales `pixelBuffer` so the longest edge is ≤ `maxDimension`,
    /// then JPEG-compresses at `jpegQuality`.
    ///
    /// - Parameter pixelBuffer: Source pixel buffer from the camera.
    /// - Returns: JPEG-compressed Data, or `nil` if the buffer cannot be locked
    ///            or if JPEG conversion fails. Never crashes.
    ///
    /// **Thread-safe**: Operates only on the input pixel buffer (read-only) and
    /// produces immutable output. No thread-unsafe global state is accessed.
    public static func encode(pixelBuffer: CVPixelBuffer) -> Data? {
        // Lock the pixel buffer for reading.
        let lockFlags = CVPixelBufferLockFlags(rawValue: 0)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, lockFlags) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, lockFlags) }

        // Create a CIImage from the locked pixel buffer.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Determine scale factor to fit the longest edge within maxDimension.
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let maxExtent = max(width, height)
        let scaleFactor = min(1.0, CGFloat(maxDimension) / maxExtent)

        // Apply scale transform if downscaling is needed.
        let scaledImage: CIImage
        if scaleFactor < 1.0 {
            let scaleTransform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
            scaledImage = ciImage.transformed(by: scaleTransform)
        } else {
            scaledImage = ciImage
        }

        // Render to UIImage, then compress as JPEG.
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)
        let jpegData = uiImage.jpegData(compressionQuality: jpegQuality)

        return jpegData
    }
}
