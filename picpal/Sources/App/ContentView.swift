import SwiftUI

/// Root view — full-screen camera preview with a toggleable debug overlay.
///
/// The camera instance is owned by this view for its lifetime. The debug overlay
/// starts with placeholder values; later tasks update `debugViewModel` with live readings.
struct ContentView: View {

    @State private var camera = CameraCapture()
    @StateObject private var debugViewModel = DebugOverlayViewModel()

    var body: some View {
        ZStack {
            CameraPreviewView(camera: camera)
                .ignoresSafeArea()

            DebugOverlayView(viewModel: debugViewModel)
        }
    }
}
