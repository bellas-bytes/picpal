import SwiftUI

/// A semi-transparent overlay that displays debug telemetry.
///
/// Tap anywhere on the screen (or the bug button in the top-right corner) to toggle
/// the panel. All values are read from `DebugOverlayViewModel`; update those
/// properties to reflect live readings from later tasks.
struct DebugOverlayView: View {

    @ObservedObject var viewModel: DebugOverlayViewModel
    @State private var isVisible: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Transparent hit area — tapping anywhere toggles the panel.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isVisible.toggle() }

            if isVisible {
                overlayPanel
                    .padding(DebugOverlayLayout.panelEdgePadding)
                    .padding(.top, DebugOverlayLayout.panelTopOffset)
            }

            toggleButton
                .padding(DebugOverlayLayout.buttonEdgePadding)
        }
    }

    // MARK: - Sub-views

    private var toggleButton: some View {
        Button(action: { isVisible.toggle() }) {
            Image(systemName: "ladybug.fill")
                .padding(DebugOverlayLayout.buttonIconPadding)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.white)
    }

    private var overlayPanel: some View {
        VStack(alignment: .leading, spacing: DebugOverlayLayout.rowSpacing) {
            debugRow(label: "Tilt",     value: String(format: "%.1f°",  viewModel.tiltDegrees))
            debugRow(label: "Blur",     value: String(format: "%.2f",   viewModel.blurScore))
            debugRow(label: "Exposure", value: viewModel.exposureLevel)
            debugRow(label: "FPS",      value: String(format: "%.1f",   viewModel.framesPerSecond))
            debugRow(label: "Thermal",  value: viewModel.thermalState)
            debugRow(label: "Drops",    value: "\(viewModel.dropCount)")
            debugRow(label: "Frame ms", value: String(format: "%.2f",   viewModel.meanFrameMs))
        }
        .padding(DebugOverlayLayout.panelInnerPadding)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: DebugOverlayLayout.panelCornerRadius)
        )
    }

    private func debugRow(label: String, value: String) -> some View {
        HStack(spacing: DebugOverlayLayout.rowLabelValueSpacing) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}

// MARK: - Layout constants

private enum DebugOverlayLayout {
    static let buttonEdgePadding: CGFloat   = 12
    static let buttonIconPadding: CGFloat   = 8
    static let panelEdgePadding: CGFloat    = 12
    static let panelTopOffset: CGFloat      = 44   // clear the toggle button row
    static let panelInnerPadding: CGFloat   = 12
    static let panelCornerRadius: CGFloat   = 10
    static let rowSpacing: CGFloat          = 6
    static let rowLabelValueSpacing: CGFloat = 8
}
