import Testing
import SwiftUI
import AVFoundation
@testable import PicPal

/// Committed-position semantics without camera hardware. A switch that cannot
/// run must not tell the UI to mirror or rotate the existing preview.
struct CameraSwitchTests {
    @Test func initialPositionIsBack() {
        #expect(CameraCapture().cameraPosition == .back)
    }

    @Test func switchWithoutRunningSessionKeepsPosition() async {
        let capture = CameraCapture()
        let position = await capture.switchCamera()
        #expect(position == .back)
        #expect(capture.cameraPosition == .back)
    }

    @Test func repeatedUnavailableSwitchesKeepPosition() async {
        let capture = CameraCapture()
        for _ in 0..<6 {
            let position = await capture.switchCamera()
            #expect(position == .back)
        }
        #expect(capture.cameraPosition == .back)
    }

    @Test func concurrentUnavailableSwitchesKeepPosition() async {
        let capture = CameraCapture()
        async let first = capture.switchCamera()
        async let second = capture.switchCamera()
        let positions = await [first, second]
        #expect(positions == [.back, .back])
        #expect(capture.cameraPosition == .back)
    }
}

@MainActor
struct CameraStageRenderingTests {
    @Test func rotatingStageRetainsPreviewAndFitsOverlays() async throws {
        let camera = CameraCapture()
        let coordinates = CameraPreviewCoordinates()
        let reference = UIGraphicsImageRenderer(size: CGSize(width: 1024, height: 768)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        }
        func content(_ size: CGSize, expanded: Bool = false) -> some View {
            CameraStage(size: size, aspectRatio: size.width > size.height ? 4.0 / 3.0 : 3.0 / 4.0) {
                ZStack {
                    CameraPreviewView(camera: camera, cameraPosition: .front, coordinateConverter: coordinates)
                    Color.blue.opacity(0.25)
                    ReferenceOverlayView(image: reference, isMatched: false, isExtracting: false, onDismiss: {})
                    VStack {
                        Text("Step back to include head and shoulders in the reference photo")
                            .font(.headline).padding()
                        Spacer()
                        ReferenceOpacityControl(opacity: .constant(0.3), referenceDescription: "Landscape reference")
                        CameraZoomControl(zoom: 1, minimum: 1, maximum: 5, multiplier: 0.5, setZoom: { _ in }, expanded: expanded)
                            .padding(.bottom, 12)
                    }
                }
            } controls: {
                VStack {
                    Text("FULL BODY    PORTRAIT")
                    HStack { Text("Flip"); Spacer(); Circle().fill(.white).frame(width: 64, height: 64); Spacer(); Text("Photo") }
                    Text("Auto capture")
                }.padding()
            }
            .background(.black).foregroundStyle(.white).ignoresSafeArea()
        }
        let host = UIHostingController(rootView: content(CGSize(width: 393, height: 730)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 730))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        var first: CameraContainerView?
        for (name, size) in [("portrait", CGSize(width: 393, height: 730)),
                             ("landscape", CGSize(width: 760, height: 340)),
                             ("portrait-return", CGSize(width: 393, height: 730))] {
            window.frame.size = size
            host.rootView = content(size)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let preview = try #require(coordinates.container)
            #expect(preview.previewLayer.session === camera.captureSession)
            if let first { #expect(preview === first) } else { first = preview }
            let rect = preview.convert(preview.bounds, to: host.view)
            #expect(rect.width > 0 && rect.height > 0)
            #expect(rect.minX >= -0.5 && rect.minY >= -0.5)
            #expect(rect.maxX <= size.width + 0.5 && rect.maxY <= size.height + 0.5)
            let screenshot = UIGraphicsImageRenderer(size: size).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-stage-\(name).png")
            try screenshot.pngData()?.write(to: url)
            print("[CameraStage render] \(name) preview=\(rect) screenshot=\(url.path)")
        }
        let expandedSize = CGSize(width: 760, height: 340)
        let expandedHost = UIHostingController(rootView: content(expandedSize, expanded: true))
        window.rootViewController = expandedHost
        window.frame.size = expandedSize
        expandedHost.view.frame = CGRect(origin: .zero, size: expandedSize)
        expandedHost.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let expandedImage = UIGraphicsImageRenderer(size: expandedSize).image { _ in
            expandedHost.view.drawHierarchy(in: expandedHost.view.bounds, afterScreenUpdates: true)
        }
        let expandedURL = FileManager.default.temporaryDirectory.appendingPathComponent("camera-stage-landscape-expanded.png")
        try expandedImage.pngData()?.write(to: expandedURL)
        print("[CameraStage render] expanded screenshot=\(expandedURL.path)")

    }
}

@Suite("Manual camera zoom")
struct ManualCameraZoomTests {
    @Test func presetsMapDisplayedStopsToRealHardwareRange() {
        #expect(CameraZoomStops.rawValues(minimum: 1, maximum: 5, multiplier: 0.5) == [1, 2, 4])
        #expect(CameraZoomStops.rawValues(minimum: 1, maximum: 5, multiplier: 1) == [1, 2, 3])
        #expect(CameraZoomStops.rawValues(minimum: 1.4, maximum: 2.5, multiplier: 1) == [1.4, 2])
    }
    @Test func blockedStartCannotResumeUntilFingersLift() {
        var pinch = CameraPinchZoom()
        pinch.cancel()
        #expect(pinch.update(magnification: 3, current: 1, minimum: 1, maximum: 5) == nil)
        pinch.reset()
        #expect(pinch.update(magnification: 1.1, current: 1, minimum: 1, maximum: 5) == 1.1)
    }
    @Test func pinchUsesOneBaselineClampsAndResetsAfterContextChange() {
        var pinch = CameraPinchZoom()
        #expect(pinch.update(magnification: 2, current: 1, minimum: 1, maximum: 5) == 2)
        #expect(pinch.update(magnification: 3, current: 2, minimum: 1, maximum: 5) == 3)
        #expect(pinch.update(magnification: 10, current: 3, minimum: 1, maximum: 5) == 5)
        #expect(pinch.update(magnification: 0.1, current: 3, minimum: 1, maximum: 5) == 1)
        pinch.cancel()
        #expect(pinch.update(magnification: 2, current: 1, minimum: 1, maximum: 5) == nil)
        pinch.reset()
        #expect(pinch.update(magnification: 2, current: 2, minimum: 1, maximum: 5) == 4)
    }
}
