import CoreGraphics
import Testing
import UIKit
@testable import PicPal

struct ReferenceGeometryTests {
    @Test func fitAndFillDiffer() {
        let fit = ReferenceGeometry(imageAspectRatio: 2, viewportAspectRatio: 1, contentMode: .fit)
        let fill = ReferenceGeometry(imageAspectRatio: 2, viewportAspectRatio: 1, contentMode: .fill)
        #expect(fit.displayPoint(CGPoint(x: 0, y: 0)).y == 0.25)
        #expect(fill.displayPoint(CGPoint(x: 0, y: 0)).x == -0.5)
    }
    @Test func mirroredDirection() {
        let geometry = ReferenceGeometry(isMirrored: true)
        #expect(geometry.displayPoint(CGPoint(x: 0.2, y: 0.7)).x == 0.2)
        #expect(geometry.canonicalPoint(CGPoint(x: 0.2, y: 0.7)).x == 0.8)
    }
    @Test func portraitFit() {
        let geometry = ReferenceGeometry(imageAspectRatio: 0.5, viewportAspectRatio: 1, contentMode: .fit)
        #expect(geometry.displayPoint(.zero).x == 0.25)
    }
}

extension ReferenceGeometryTests {
    @Test func referenceBoxMatchesLandscapeLetterboxInPortraitPreview() {
        let geometry = ReferenceGeometry(imageAspectRatio: 2, isMirrored: true)
        let box = geometry.aspectFitDisplayBox(CGRect(x: 0.1, y: 0, width: 0.2, height: 1), viewportAspectRatio: 0.75)
        #expect(abs(box.minX - 0.1) < 0.0001)
        #expect(abs(box.minY - 0.3125) < 0.0001)
        #expect(abs(box.height - 0.375) < 0.0001)
    }
}

extension ReferenceGeometryTests {
    @Test @MainActor func uprightPixelsPreserveRotationAndMirror() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            UIColor.blue.setFill(); context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        }
        let cg = try #require(source.cgImage)
        for orientation in [UIImage.Orientation.right, .left, .rightMirrored, .leftMirrored] {
            let upright = ReferenceBodyTracker.uprightImage(UIImage(cgImage: cg, scale: 1, orientation: orientation))
            #expect(upright.imageOrientation == .up)
            #expect(upright.size == CGSize(width: 2, height: 4))
        }
        let ordinary = ReferenceBodyTracker.uprightImage(source)
        let mirrored = ReferenceBodyTracker.uprightImage(UIImage(cgImage: cg, scale: 1, orientation: .upMirrored))
        func rgba(_ image: UIImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 32)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: 4, height: 2,
                    bitsPerComponent: 8, bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(try #require(image.cgImage), in: CGRect(x: 0, y: 0, width: 4, height: 2))
            }
            return bytes
        }
        let a = try rgba(ordinary), b = try rgba(mirrored)
        #expect(a[0] > a[2])
        #expect(b[0] < b[2])
    }
}
