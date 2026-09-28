import Foundation

/// Coordinates are oriented image fractions, origin bottom-left. Mirroring describes
/// the image pixels, not joint identity. Image aspect corrects limb angles; viewport
/// transforms are only used for framing. Reference framing uses the same aspect-fit transform as its overlay.
public struct ReferenceGeometry: Sendable {
    public enum ContentMode: Sendable { case fit, fill }
    public let imageAspectRatio: Double
    public let viewportAspectRatio: Double
    public let isMirrored: Bool
    public let contentMode: ContentMode

    public init(imageAspectRatio: Double = 1, viewportAspectRatio: Double? = nil,
                isMirrored: Bool = false, contentMode: ContentMode = .fill) {
        self.imageAspectRatio = imageAspectRatio.isFinite && imageAspectRatio > 0 ? imageAspectRatio : 1
        self.viewportAspectRatio = viewportAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? self.imageAspectRatio
        self.isMirrored = isMirrored
        self.contentMode = contentMode
    }

    public func canonicalPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: isMirrored ? 1 - point.x : point.x, y: point.y)
    }

    public func displayPoint(_ point: CGPoint) -> CGPoint {
        let ratio = imageAspectRatio / viewportAspectRatio
        let sx: Double
        let sy: Double
        switch contentMode {
        case .fill: sx = max(1, ratio); sy = max(1, 1 / ratio)
        case .fit: sx = min(1, ratio); sy = min(1, 1 / ratio)
        }
        // Pixel observations already include capture mirroring. Keep that displayed
        // position so an asymmetric reference overlay has the same target on screen.
        let p = point
        return CGPoint(x: (p.x - 0.5) * sx + 0.5, y: (p.y - 0.5) * sy + 0.5)
    }

    public func displayBox(_ box: CGRect) -> CGRect {
        let a = displayPoint(CGPoint(x: box.minX, y: box.minY))
        let b = displayPoint(CGPoint(x: box.maxX, y: box.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

extension ReferenceGeometry {
    public func aspectFitDisplayBox(_ box: CGRect, viewportAspectRatio: Double) -> CGRect {
        ReferenceGeometry(imageAspectRatio: imageAspectRatio,
            viewportAspectRatio: viewportAspectRatio, isMirrored: isMirrored,
            contentMode: .fit).displayBox(box)
    }
}
