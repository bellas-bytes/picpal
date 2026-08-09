import XCTest
@testable import PicPal

final class CaptureStateTests: XCTestCase {

    // MARK: - Identity equality

    func testIdleEqualsIdle() {
        XCTAssertEqual(CameraCapture.CaptureState.idle, .idle)
    }

    func testStartingEqualsStarting() {
        XCTAssertEqual(CameraCapture.CaptureState.starting, .starting)
    }

    func testRunningEqualsRunning() {
        XCTAssertEqual(CameraCapture.CaptureState.running, .running)
    }

    func testStoppingEqualsStopping() {
        XCTAssertEqual(CameraCapture.CaptureState.stopping, .stopping)
    }

    func testPermissionDeniedEqualsPermissionDenied() {
        XCTAssertEqual(CameraCapture.CaptureState.permissionDenied, .permissionDenied)
    }

    func testPermissionRestrictedEqualsPermissionRestricted() {
        XCTAssertEqual(CameraCapture.CaptureState.permissionRestricted, .permissionRestricted)
    }

    // MARK: - Error state equality

    func testErrorWithSameMessageIsEqual() {
        XCTAssertEqual(
            CameraCapture.CaptureState.error("camera unavailable"),
            CameraCapture.CaptureState.error("camera unavailable")
        )
    }

    func testErrorWithDifferentMessagesIsNotEqual() {
        XCTAssertNotEqual(
            CameraCapture.CaptureState.error("foo"),
            CameraCapture.CaptureState.error("bar")
        )
    }

    // MARK: - Cross-case inequality

    func testIdleIsNotRunning() {
        XCTAssertNotEqual(CameraCapture.CaptureState.idle, .running)
    }

    func testRunningIsNotPermissionDenied() {
        XCTAssertNotEqual(CameraCapture.CaptureState.running, .permissionDenied)
    }

    func testErrorIsNotIdle() {
        XCTAssertNotEqual(CameraCapture.CaptureState.error("x"), .idle)
    }

    func testPermissionDeniedIsNotPermissionRestricted() {
        XCTAssertNotEqual(
            CameraCapture.CaptureState.permissionDenied,
            .permissionRestricted
        )
    }
}
