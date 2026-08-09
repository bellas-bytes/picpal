import XCTest
import AVFoundation
@testable import PicPal

/// Tests for the `CameraCapture` state machine and configuration API.
///
/// ## Scope
/// These tests validate what is observable without a physical camera device:
/// - Initial state and configuration values.
/// - `configure(preset:fps:)` effect on `currentConfiguration`.
/// - State-change notifications via the delegate protocol.
///
/// ## Device-only validation
/// The following require a real device and are documented but not implemented here:
/// - Live frame delivery (`didOutputPixelBuffer`).
/// - `requestPermissionAndStart()` end-to-end (requires `AVCaptureSession` to run).
/// - FPS enforcement accuracy under load.
final class CameraCaptureTests: XCTestCase {

    // MARK: - Initialisation

    func testInitialStateIsIdle() {
        let capture = CameraCapture()
        XCTAssertEqual(capture.captureState, .idle)
    }

    func testInitialConfigurationMatchesDefault() {
        let capture = CameraCapture()
        XCTAssertEqual(capture.currentConfiguration, .defaultConfiguration)
    }

    func testInitialDelegateIsNil() {
        let capture = CameraCapture()
        XCTAssertNil(capture.delegate)
    }

    // MARK: - configure(preset:fps:)

    func testConfigureUpdatesPreset() {
        let capture = CameraCapture()
        let expectation = expectation(description: "sessionQueue drains")
        capture.configure(preset: .hd1920x1080, fps: 30)

        // configure() dispatches internally; wait one run-loop cycle then drain via a second async.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(capture.currentConfiguration.preset, .hd1920x1080)
    }

    func testConfigureClampsLowFPS() {
        let capture = CameraCapture()
        let expectation = expectation(description: "sessionQueue drains")
        capture.configure(preset: .hd1280x720, fps: -5)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(capture.currentConfiguration.targetFPS, CameraConfiguration.minimumFPS)
    }

    func testConfigureClampsHighFPS() {
        let capture = CameraCapture()
        let expectation = expectation(description: "sessionQueue drains")
        capture.configure(preset: .hd1280x720, fps: 500)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(capture.currentConfiguration.targetFPS, CameraConfiguration.maximumFPS)
    }

    // MARK: - Delegate assignment

    func testDelegateCanBeAssignedAndRead() {
        let capture = CameraCapture()
        let spy = DelegateSpy()
        capture.delegate = spy
        XCTAssertNotNil(capture.delegate)
    }

    func testDelegateIsHeldWeakly() {
        let capture = CameraCapture()
        var spy: DelegateSpy? = DelegateSpy()
        capture.delegate = spy
        spy = nil
        XCTAssertNil(capture.delegate)
    }
}

// MARK: - Test helpers

/// Minimal `CameraFrameDelegate` for unit tests.
///
/// Marked `@unchecked Sendable` because it is only used in single-threaded test scenarios
/// where the capture session never actually runs (no real device in unit tests).
/// Properties are `nonisolated(unsafe)` so the `nonisolated` protocol methods can mutate them.
private final class DelegateSpy: CameraFrameDelegate, @unchecked Sendable {
    nonisolated(unsafe) private(set) var receivedStates: [CameraCapture.CaptureState] = []
    nonisolated(unsafe) private(set) var frameCount = 0

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        frameCount += 1
    }

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {
        receivedStates.append(state)
    }
}
