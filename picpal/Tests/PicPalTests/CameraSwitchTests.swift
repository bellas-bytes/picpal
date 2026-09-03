import Testing
import AVFoundation
@testable import PicPal

/// Tests for `CameraCapture.switchCamera()` position-toggle behaviour.
///
/// ## Scope
/// These tests verify position toggling in isolation — no physical camera is required.
/// The session is never started, so the reconfiguration block on `sessionQueue` is a
/// no-op (guarded by `.running` state check), but the position lock itself is updated
/// synchronously before the async dispatch, which is what these tests exercise.
struct CameraSwitchTests {

    @Test func initialPositionIsBack() {
        let capture = CameraCapture()
        #expect(capture.cameraPosition == .back)
    }

    @Test func switchCameraFlipsToFront() {
        let capture = CameraCapture()
        capture.switchCamera()
        #expect(capture.cameraPosition == .front)
    }

    @Test func switchCameraTwiceReturnsToBack() {
        let capture = CameraCapture()
        capture.switchCamera()
        capture.switchCamera()
        #expect(capture.cameraPosition == .back)
    }

    @Test func switchCameraAlternatesCorrectly() {
        let capture = CameraCapture()
        let positions: [AVCaptureDevice.Position] = (0..<6).map { i in
            capture.switchCamera()
            return capture.cameraPosition
        }
        let expected: [AVCaptureDevice.Position] = [.front, .back, .front, .back, .front, .back]
        #expect(positions == expected)
    }
}
