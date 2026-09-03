import SwiftUI

// MARK: - EVDismissHandle

/// Holds a cancellable Task that auto-dismisses the EV slider after inactivity.
///
/// Declared as a `final class` (reference type) so `@Sendable` closures that capture
/// it by value still share the same underlying storage. Mirrors `AestheticExpiryHandle`.
final class EVDismissHandle: @unchecked Sendable {
    /// The pending dismiss task. Always read and written on `@MainActor`.
    nonisolated(unsafe) var task: Task<Void, Never>?
}

// MARK: - Private constants

private let evSliderWidth:     CGFloat = 28
private let evSliderHeight:    CGFloat = 120
private let focusSquareSize:   CGFloat = 70
private let evDismissSeconds:  Double  = 3.0
/// Offset from the tap point to the leading edge of the EV slider container.
private let evSliderXOffset:   CGFloat = 50
private let evSliderMinX:      CGFloat = 60

// MARK: - ContentView+ExposureControl

extension ContentView {

    // MARK: - Overlay entry point

    /// Tap-to-focus overlay with EV slider. Inserted into the main ZStack.
    @ViewBuilder
    var exposureControlOverlay: some View {
        GeometryReader { geo in
            ZStack {
                // Tap capture layer (transparent, covers the whole preview).
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { _ in
                        handleDoubleTap()
                    }
                    .onTapGesture { location in
                        handleTap(at: location, in: geo.size)
                    }

                if showEVControls, let point = exposureTapPoint {
                    // Focus square
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: focusSquareSize, height: focusSquareSize)
                        .position(point)
                        .transition(.opacity.animation(.easeOut(duration: 0.3)))

                    // EV slider positioned to the right of the focus square.
                    evSliderView(tapPoint: point, in: geo.size)
                        .transition(.opacity.animation(.easeIn(duration: 0.2)))
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - EV slider view

    @ViewBuilder
    private func evSliderView(tapPoint: CGPoint, in size: CGSize) -> some View {
        let sliderX = min(size.width - evSliderMinX, tapPoint.x + evSliderXOffset)
        let sliderY = tapPoint.y.clamped(to: (evSliderHeight / 2 + 8)...(size.height - evSliderHeight / 2 - 8))

        VStack(spacing: 4) {
            Image(systemName: "sun.max")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Slider(
                value: Binding(
                    get: { Double(evBias) },
                    set: { newVal in
                        evBias = Float(newVal)
                        camera.setExposureBias(evBias)
                        cueEngine?.suppressExposureCue = camera.exposureBiasIsManual
                        scheduleEVDismiss()
                    }
                ),
                in: -2...2
            )
            .rotationEffect(.degrees(-90))
            .frame(width: evSliderHeight, height: evSliderWidth)
            Image(systemName: "sun.min")
                .font(.caption2)
                .foregroundStyle(.yellow)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .position(x: sliderX, y: sliderY)
    }

    // MARK: - Gesture handlers

    private func handleTap(at location: CGPoint, in size: CGSize) {
        let devicePoint = devicePoint(from: location, viewSize: size)
        camera.setFocusAndExposure(at: devicePoint)
        withAnimation(.easeOut(duration: 0.25)) {
            exposureTapPoint = location
            showEVControls = true
        }
        scheduleEVDismiss()
    }

    private func handleDoubleTap() {
        resetEV()
    }

    // MARK: - Reset

    private func resetEV() {
        evBias = 0
        camera.setExposureBias(0)
        cueEngine?.suppressExposureCue = false
        withAnimation(.easeOut(duration: 0.2)) {
            showEVControls = false
            exposureTapPoint = nil
        }
        evDismissHandle.task?.cancel()
        evDismissHandle.task = nil
    }

    // MARK: - Auto-dismiss

    private func scheduleEVDismiss() {
        evDismissHandle.task?.cancel()
        let handle = evDismissHandle
        handle.task = Task { @MainActor [weak evDismissHandle] in
            try? await Task.sleep(for: .seconds(evDismissSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                showEVControls = false
            }
            evDismissHandle?.task = nil
        }
    }

    // MARK: - Coordinate conversion

    /// Converts a view-space tap location to normalized device coordinates (0–1).
    ///
    /// For a back camera in portrait orientation the sensor is landscape — the mapping
    /// swaps axes: sensor-x ← view-y/height, sensor-y ← 1 − view-x/width.
    private func devicePoint(from viewPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        let x = viewSize.height > 0 ? viewPoint.y / viewSize.height : 0.5
        let y = viewSize.width  > 0 ? 1 - viewPoint.x / viewSize.width : 0.5
        return CGPoint(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
    }
}

// MARK: - Comparable clamped helper (used in this file)

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
