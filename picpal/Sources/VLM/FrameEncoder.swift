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
    // CIContext supports concurrent rendering; images and render destinations remain per call.
    private static let context = CIContext()


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
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        let uiImage = UIImage(cgImage: cgImage)
        let jpegData = uiImage.jpegData(compressionQuality: jpegQuality)

        return jpegData
    }

    // MARK: - Two-image overload (reference mode)

    /// Encodes a live frame alongside a reference image for VLM comparison.
    ///
    /// Both images are downscaled so their longest edge is ≤ `maxDimension` and
    /// JPEG-compressed at `jpegQuality`.  Returns `nil` if either encode step fails.
    ///
    /// - Parameters:
    ///   - pixelBuffer: Live camera frame.
    ///   - referenceImage: Reference photo selected by the user.
    /// - Returns: A named tuple `(liveData:referenceData:)`, or `nil` on failure.
    ///
    /// **No I/O**: Neither image is written to disk.  The returned `Data` values
    /// exist only in memory and are transmitted inside the VLM request body.
    public static func encode(
        pixelBuffer: CVPixelBuffer,
        referenceImage: UIImage
    ) -> (liveData: Data, referenceData: Data)? {
        guard let liveData = encode(pixelBuffer: pixelBuffer) else { return nil }
        guard let referenceData = encodeUIImage(referenceImage) else { return nil }
        return (liveData: liveData, referenceData: referenceData)
    }

    // MARK: - Private helpers

    /// Downscales `image` so its longest edge is ≤ `maxDimension`, then JPEG-compresses it.
    static func encodeUIImage(_ image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let maxExtent = max(size.width, size.height)
        let scaleFactor = min(1.0, CGFloat(maxDimension) / maxExtent)

        let targetSize: CGSize
        if scaleFactor < 1.0 {
            targetSize = CGSize(
                width: (size.width * scaleFactor).rounded(),
                height: (size.height * scaleFactor).rounded()
            )
        } else {
            targetSize = size
        }

        // Force scale = 1.0 so Retina display factors don't inflate pixel dimensions.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return scaled.jpegData(compressionQuality: jpegQuality)
    }
}
