import Testing
@testable import PicPal

struct PhotoCaptureTests {
    @Test func idleCameraCannotCapture() async {
        let camera = CameraCapture()
        do {
            _ = try await camera.capturePhoto()
            Issue.record("Idle camera should reject capture")
        } catch {
            #expect(error as? PhotoCaptureError == .unavailable)
        }
        let status = await camera.cameraStatus()
        #expect(!status.isReady)
        #expect(status.zoomFactor == 1)
        #expect(!status.supportsFlash)
    }
}
