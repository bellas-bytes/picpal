import Testing
@testable import PicPal

struct CaptureStateTests {

    // MARK: - Identity equality

    @Test func idleEqualsIdle() {
        #expect(CameraCapture.CaptureState.idle == .idle)
    }

    @Test func startingEqualsStarting() {
        #expect(CameraCapture.CaptureState.starting == .starting)
    }

    @Test func runningEqualsRunning() {
        #expect(CameraCapture.CaptureState.running == .running)
    }

    @Test func stoppingEqualsStopping() {
        #expect(CameraCapture.CaptureState.stopping == .stopping)
    }

    @Test func permissionDeniedEqualsPermissionDenied() {
        #expect(CameraCapture.CaptureState.permissionDenied == .permissionDenied)
    }

    @Test func permissionRestrictedEqualsPermissionRestricted() {
        #expect(CameraCapture.CaptureState.permissionRestricted == .permissionRestricted)
    }

    // MARK: - Error state equality

    @Test func errorWithSameMessageIsEqual() {
        #expect(CameraCapture.CaptureState.error("camera unavailable") == .error("camera unavailable"))
    }

    @Test func errorWithDifferentMessagesIsNotEqual() {
        #expect(CameraCapture.CaptureState.error("foo") != .error("bar"))
    }

    // MARK: - Cross-case inequality

    @Test func idleIsNotRunning() {
        #expect(CameraCapture.CaptureState.idle != .running)
    }

    @Test func runningIsNotPermissionDenied() {
        #expect(CameraCapture.CaptureState.running != .permissionDenied)
    }

    @Test func errorIsNotIdle() {
        #expect(CameraCapture.CaptureState.error("x") != .idle)
    }

    @Test func permissionDeniedIsNotPermissionRestricted() {
        #expect(CameraCapture.CaptureState.permissionDenied != .permissionRestricted)
    }
}
