import SwiftUI

/// Composites a ghost reference image over the live camera feed.
///
/// Place this view in `ContentView`'s ZStack between the camera preview layer and
/// the debug overlay. The caller owns match detection and extraction state; this
/// view only renders them.
///
/// The chosen opacity is preserved during extraction and matching.
/// The close button remains available when the ghost is fully transparent.
struct ReferenceOverlayView: View {

    // MARK: - Properties

    /// The reference image to ghost over the live feed.
    let image: UIImage
    /// True when the live pose matches the reference pose.
    let isMatched: Bool
    /// True while Vision pose extraction is running.
    let isExtracting: Bool
    /// True when pose extraction completed with an error (e.g. no person detected).
    /// Defaults to `false` so existing call sites without this argument still compile.
    var extractionFailed: Bool = false
    /// Only the active, measured pose adjustment is highlighted.
    var guidanceTarget: PoseGuidanceTarget? = nil
    var opacity: Double = 0.30
    /// Called on X-button tap or swipe-down gesture.
    let onDismiss: () -> Void

    // MARK: - Layout constants

    private enum Layout {
        static let dismissButtonSize: CGFloat = 32
        static let dismissButtonPadding: CGFloat = 16
        static let xmarkSymbol = "xmark.circle.fill"
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Inner ZStack centres the ProgressView / error overlay over the ghost image.
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(currentOpacity)
                    .overlay(matchTintOverlay)
                    .animation(.easeInOut(duration: 0.4), value: isMatched)
                    .allowsHitTesting(false)

                if isExtracting {
                    ProgressView()
                } else if extractionFailed {
                    extractionErrorOverlay
                }

                if !isExtracting, !extractionFailed, let target = guidanceTarget,
                   target.point.x.isFinite, target.point.y.isFinite,
                   (0...1).contains(target.point.x), (0...1).contains(target.point.y) {
                    GeometryReader { geometry in
                        ZStack {
                            Circle().stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                                .frame(width: 32, height: 32)
                            Circle().fill(.white).frame(width: 5, height: 5)
                        }
                        .shadow(color: .black.opacity(0.8), radius: 3)
                        .position(x: target.point.x * geometry.size.width, y: target.point.y * geometry.size.height)
                    }
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Pose target: \(target.label)")
                }
            }

            dismissButton
        }
    }

    // MARK: - Opacity

    var currentOpacity: Double { opacity.isFinite ? min(1, max(0, opacity)) : 0.30 }
    var matchTintOpacity: Double { isMatched ? 0.35 * currentOpacity : 0 }

    // MARK: - Sub-views

    private var matchTintOverlay: some View {
        Color.green.opacity(matchTintOpacity)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: Layout.xmarkSymbol)
                .font(.system(size: Layout.dismissButtonSize))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(Layout.dismissButtonPadding)
    }

    private var extractionErrorOverlay: some View {
        VStack(spacing: 12) {
            Text("Choose another reference photo")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("OK", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

}
