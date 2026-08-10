import SwiftUI

// MARK: - Style constants

private enum GuidesStyle {
    static let gridOpacity: Double = 0.25
    static let gridLineWidth: CGFloat = 1
    static let levelLineWidth: CGFloat = 2
    static let levelColorLevel: Color = .green
    static let levelColorTilted: Color = Color.white.opacity(0.6)
    static let subjectBoxOpacity: Double = 0.8
    static let subjectBoxLineWidth: CGFloat = 2
    static let subjectBoxDashOn: CGFloat = 8
    static let subjectBoxDashOff: CGFloat = 4
}

private enum ThirdsGrid {
    static let oneThird: Double = 1.0 / 3.0
    static let twoThirds: Double = 2.0 / 3.0
}

// MARK: - Coordinate conversion

/// Converts a Vision-space normalized rectangle (origin bottom-left, y increases up)
/// into a SwiftUI-space rectangle (origin top-left, y increases down) scaled to `size`.
func visionRectToSwiftUI(_ visionRect: CGRect, in size: CGSize) -> CGRect {
    let uiKitRect = CGRect(
        x: visionRect.minX,
        y: 1 - visionRect.maxY,
        width: visionRect.width,
        height: visionRect.height
    )
    return CGRect(
        x: uiKitRect.minX * size.width,
        y: uiKitRect.minY * size.height,
        width: uiKitRect.width * size.width,
        height: uiKitRect.height * size.height
    )
}

// MARK: - View

/// An always-visible overlay drawn on top of the camera preview.
///
/// Draws three guides:
/// 1. Rule-of-thirds grid (four faint lines).
/// 2. Level indicator (horizontal line that rotates and turns green when level).
/// 3. Subject box (dashed rectangle around the primary subject, when detected).
struct GuidesOverlayView: View {

    @ObservedObject var viewModel: DebugOverlayViewModel

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // Rule-of-thirds grid
                thirdsGrid(in: size)

                // Level indicator
                levelLine(in: size)

                // Subject box (conditional)
                if let box = viewModel.subjectBox {
                    subjectBoxPath(visionRect: box, in: size)
                }
            }
        }
    }

    // MARK: - Sub-views

    private func thirdsGrid(in size: CGSize) -> some View {
        Canvas { ctx, _ in
            let w = size.width
            let h = size.height
            let color = Color.white.opacity(GuidesStyle.gridOpacity)
            let style = StrokeStyle(lineWidth: GuidesStyle.gridLineWidth)

            // Vertical lines at 1/3 and 2/3
            for fraction in [ThirdsGrid.oneThird, ThirdsGrid.twoThirds] {
                var path = Path()
                let x = w * fraction
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(path, with: .color(color), style: style)
            }

            // Horizontal lines at 1/3 and 2/3
            for fraction in [ThirdsGrid.oneThird, ThirdsGrid.twoThirds] {
                var path = Path()
                let y = h * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: w, y: y))
                ctx.stroke(path, with: .color(color), style: style)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func levelLine(in size: CGSize) -> some View {
        let tiltDegrees = viewModel.tiltDegrees
        let isLevel = viewModel.isLevel
        let color = isLevel ? GuidesStyle.levelColorLevel : GuidesStyle.levelColorTilted

        return Canvas { ctx, canvasSize in
            var path = Path()
            let midY = canvasSize.height / 2
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: canvasSize.width, y: midY))
            ctx.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: GuidesStyle.levelLineWidth)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .rotationEffect(.degrees(tiltDegrees))
        .allowsHitTesting(false)
    }

    private func subjectBoxPath(visionRect: CGRect, in size: CGSize) -> some View {
        let rect = visionRectToSwiftUI(visionRect, in: size)
        let color = Color.yellow.opacity(GuidesStyle.subjectBoxOpacity)
        let dash: [CGFloat] = [GuidesStyle.subjectBoxDashOn, GuidesStyle.subjectBoxDashOff]

        return Canvas { ctx, _ in
            let path = Path(rect)
            ctx.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: GuidesStyle.subjectBoxLineWidth,
                    dash: dash
                )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
