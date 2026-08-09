import Testing
import AVFoundation
@testable import PicPal

/// Tests for the `CameraCapture` state machine and configuration API.
///
/// ## Scope
/// These tests validate what is observable without a physical camera device:
/// - Initial state and configuration values.
/// - `configure(preset:fps:)` effect on `currentConfiguration`.
/// - Delegate weak-reference semantics.
///
/// ## Device-only validation
/// The following require a real device and are documented but not implemented here:
/// - Live frame delivery (`didOutputPixelBuffer`).
/// - `requestPermissionAndStart()` end-to-end (requires `AVCaptureSession` to run).
/// - FPS enforcement accuracy under load.
struct CameraCaptureTests {

    // MARK: - Initialisation

    @Test func initialStateIsIdle() {
        let capture = CameraCapture()
        #expect(capture.captureState == .idle)
    }

    @Test func initialConfigurationMatchesDefault() {
        let capture = CameraCapture()
        #expect(capture.currentConfiguration == .defaultConfiguration)
    }

    @Test func initialDelegateIsNil() {
        let capture = CameraCapture()
        #expect(capture.delegate == nil)
    }

    // MARK: - configure(preset:fps:)

    @Test func configureUpdatesPreset() async throws {
        let capture = CameraCapture()
        capture.configure(preset: .hd1920x1080, fps: 30)
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.currentConfiguration.preset == .hd1920x1080)
    }

    @Test func configureClampsLowFPS() async throws {
        let capture = CameraCapture()
        capture.configure(preset: .hd1280x720, fps: -5)
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.currentConfiguration.targetFPS == CameraConfiguration.minimumFPS)
    }

    @Test func configureClampsHighFPS() async throws {
        let capture = CameraCapture()
        capture.configure(preset: .hd1280x720, fps: 500)
        try await Task.sleep(for: .milliseconds(150))
        #expect(capture.currentConfiguration.targetFPS == CameraConfiguration.maximumFPS)
    }

    // MARK: - Delegate assignment

    @Test func delegateCanBeAssignedAndRead() {
        let capture = CameraCapture()
        let spy = DelegateSpy()
        capture.delegate = spy
        #expect(capture.delegate != nil)
    }

    @Test func delegateIsHeldWeakly() {
        let capture = CameraCapture()
        var spy: DelegateSpy? = DelegateSpy()
        capture.delegate = spy
        spy = nil
        #expect(capture.delegate == nil)
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
