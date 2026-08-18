import SwiftUI

/// Composites a ghost reference image over the live camera feed.
///
/// Place this view in `ContentView`'s ZStack between the camera preview layer and
/// the debug overlay. The caller owns match detection and extraction state; this
/// view only renders them.
///
/// ## State transitions
/// - **Idle** (`isMatched == false`, `isExtracting == false`): ghost image at 30 % opacity.
/// - **Extracting** (`isExtracting == true`): ghost image at 15 % opacity + centred `ProgressView`.
/// - **Matched** (`isMatched == true`, `isExtracting == false`): ghost image at 15 % opacity
///   with a green tint overlay, animated via `.easeInOut(duration: 0.4)`.
///
/// ## Dismissal
/// Both the X button (top-trailing) and a downward swipe (`translation.height > 0`)
/// invoke `onDismiss`.
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
    /// Called on X-button tap or swipe-down gesture.
    let onDismiss: () -> Void

    // MARK: - Layout constants

    private enum Layout {
        static let defaultOpacity: Double = 0.30
        static let matchOpacity: Double = 0.15
        static let matchTint: Color = .green.opacity(0.35)
        static let dismissButtonSize: CGFloat = 32
        static let dismissButtonPadding: CGFloat = 16
        static let extractingOpacity: Double = 0.15
        static let swipeMinimumDistance: CGFloat = 40
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
                    .gesture(swipeToDismiss)

                if isExtracting {
                    ProgressView()
                } else if extractionFailed {
                    extractionErrorOverlay
                }
            }

            dismissButton
        }
    }

    // MARK: - Opacity

    /// Current opacity of the ghost image, driven by `isExtracting` and `isMatched`.
    ///
    /// `isExtracting` takes priority so the loading indicator is always visible
    /// during Vision inference.
    var currentOpacity: Double {
        if isExtracting { return Layout.extractingOpacity }
        return isMatched ? Layout.matchOpacity : Layout.defaultOpacity
    }

    // MARK: - Sub-views

    private var matchTintOverlay: some View {
        isMatched ? Layout.matchTint : Color.clear
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
            Text("No person detected — try another photo")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("OK", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var swipeToDismiss: some Gesture {
        DragGesture(minimumDistance: Layout.swipeMinimumDistance)
            .onEnded { value in
                if value.translation.height > 0 { onDismiss() }
            }
    }
}
