import CoreGraphics

/// Plans zoom about the optical center, preserving subject margins before enlarging it.
enum AutomaticZoomPlanner {
    static func target(current: CGFloat, minZoom: CGFloat, maxZoom: CGFloat,
                       box: CGRect, style: ShotStyle) -> CGFloat {
        guard current.isFinite, current > 0, minZoom.isFinite, minZoom > 0,
              maxZoom.isFinite, maxZoom >= minZoom,
              box.origin.x.isFinite, box.origin.y.isFinite,
              box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
            return current.isFinite && current > 0 ? current : 1
        }
        let upperZoom = max(minZoom, min(maxZoom, 2))
        let desiredHeight: CGFloat = style == .fullBody ? 0.72 : 0.8
        var ratio = desiredHeight / box.height
        // A tiny inset avoids rounding an exact boundary into clipping advice on the next observation.
        let inset: CGFloat = 0.002
        func constrainLower(_ edge: CGFloat, margin: CGFloat) {
            if edge < 0.5 { ratio = min(ratio, (0.5 - margin - inset) / (0.5 - edge)) }
        }
        func constrainUpper(_ edge: CGFloat, margin: CGFloat) {
            if edge > 0.5 { ratio = min(ratio, (margin - inset - 0.5) / (edge - 0.5)) }
        }
        constrainLower(box.minX, margin: 0.025)
        constrainUpper(box.maxX, margin: 0.975)
        // Keep the coach's accepted center/thirds placement viable after zoom too.
        constrainLower(box.midX, margin: 0.25)
        constrainUpper(box.midX, margin: 0.75)
        constrainUpper(box.maxY, margin: style == .fullBody ? 0.965 : 0.98)
        if style == .fullBody { constrainLower(box.minY, margin: 0.035) }
        return min(upperZoom, max(minZoom, current * ratio))
    }
}
