import Testing
import AVFoundation
import UIKit
@testable import PicPal

struct CameraConfigurationTests {

    // MARK: - Default configuration

    @Test func defaultPresetIs720p() {
        #expect(CameraConfiguration.defaultConfiguration.preset == .hd1280x720)
    }

    @Test func defaultFPSIs30() {
        #expect(CameraConfiguration.defaultConfiguration.targetFPS == 30)
    }

    // MARK: - FPS clamping

    @Test func fpsBelowMinimumClampsToMinimum() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: -10)
        #expect(config.targetFPS == CameraConfiguration.minimumFPS)
    }

    @Test func fpsOfZeroClampsToMinimum() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: 0)
        #expect(config.targetFPS == CameraConfiguration.minimumFPS)
    }

    @Test func fpsAboveMaximumClampsToMaximum() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: 999)
        #expect(config.targetFPS == CameraConfiguration.maximumFPS)
    }

    @Test func fpsAtMinimumBoundaryIsAccepted() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: CameraConfiguration.minimumFPS)
        #expect(config.targetFPS == CameraConfiguration.minimumFPS)
    }

    @Test func fpsAtMaximumBoundaryIsAccepted() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: CameraConfiguration.maximumFPS)
        #expect(config.targetFPS == CameraConfiguration.maximumFPS)
    }

    @Test func fpsWithinRangeIsStoredUnchanged() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: 24)
        #expect(config.targetFPS == 24)
    }

    // MARK: - Constant sanity

    @Test func minimumFPSIsPositive() {
        #expect(CameraConfiguration.minimumFPS > 0)
    }

    @Test func maximumFPSExceedsMinimum() {
        #expect(CameraConfiguration.maximumFPS > CameraConfiguration.minimumFPS)
    }

    // MARK: - Equatable

    @Test func configurationsWithSameValuesAreEqual() {
        let a = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        let b = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        #expect(a == b)
    }

    @Test func configurationsWithDifferentPresetsAreNotEqual() {
        let a = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        let b = CameraConfiguration(preset: .hd1920x1080, targetFPS: 30)
        #expect(a != b)
    }

    @Test func configurationsWithDifferentFPSAreNotEqual() {
        let a = CameraConfiguration(preset: .hd1280x720, targetFPS: 24)
        let b = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        #expect(a != b)
    }
}

struct CaptureOrientationTests {
    @Test func sceneOrientationDrivesMatchingPreviewAndPhotoOrientation() {
        for interface in [UIInterfaceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            let capture = CaptureOrientation.portrait.updated(forInterface: interface)
            #expect(capture.videoOrientation.rawValue == interface.rawValue)
            #expect(capture.previewAspectRatio == (interface == .portrait ? 0.75 : 4.0 / 3.0))
        }
    }

    @Test func transientUnknownSceneRetainsCurrentCaptureOrientation() {
        #expect(CaptureOrientation.landscapeRight.updated(forInterface: .unknown) == .landscapeRight)
    }
    @Test func retainsLastOrientationForFlatUnknownAndUpsideDown() {
        for reading in [UIDeviceOrientation.unknown, .faceUp, .faceDown, .portraitUpsideDown] {
            #expect(CaptureOrientation.landscapeLeft.updated(for: reading) == .landscapeLeft)
        }
    }
    @Test func deviceAndCaptureLandscapeDirectionsAreOpposite() {
        #expect(CaptureOrientation.portrait.updated(for: .landscapeLeft).videoOrientation == .landscapeRight)
        #expect(CaptureOrientation.portrait.updated(for: .landscapeRight).videoOrientation == .landscapeLeft)
    }
    @Test func landscapeHorizonIsLevelInBothDirections() {
        #expect(abs(CaptureOrientation.landscapeLeft.relativeRoll(-Double.pi / 2)) < 0.0001)
        #expect(abs(CaptureOrientation.landscapeRight.relativeRoll(Double.pi / 2)) < 0.0001)
        #expect(abs(CaptureOrientation.portrait.relativeRoll(0.1) - 0.1) < 0.0001)
    }
}

struct SelfieFramingAdviceTests {
    @Test func suggestsAvailableZoomBeforePhysicalMovement() {
        #expect(SelfieFramingAdvice.caption(direction: "move_back", zoom: 1, minimumZoom: 0.5)
            == "Zoom out to match the selfie framing")
        #expect(SelfieFramingAdvice.caption(direction: "move_back", zoom: 0.5, minimumZoom: 0.5)
            == "Widest selfie view — match your head and hand pose")
        #expect(SelfieFramingAdvice.caption(direction: "selfie_hand_position", zoom: 1, minimumZoom: 0.5) == nil)
    }
}

@MainActor
struct CameraPreviewNotificationTests {
    @Test(arguments: [CameraCapture.connectionsChangedNotification, AVCaptureSession.didStartRunningNotification])
    func backgroundCameraNotificationDoesNotEnterMainActorSynchronously(name: Notification.Name) async {
        let container = CameraContainerView()
        let coordinator = CameraPreviewView.Coordinator()
        let session = PreviewTestSession()
        coordinator.attach(container: container, to: session.value)
        // Real camera startup posts on its serial session queue, not the main actor.
        // This previously trapped inside the Combine sink before its Task could run.
        await Task.detached {
            NotificationCenter.default.post(name: name, object: session.value)
        }.value
        await Task.yield()
        #expect(container.previewLayer.session === session.value)
        withExtendedLifetime(coordinator) {}
    }
}

private final class PreviewTestSession: @unchecked Sendable {
    let value = AVCaptureSession()
}

@MainActor
struct CameraSceneRotationRequestTests {
    @Test func physicalRotationRequestsMatchingSceneOnceUntilDirectionChanges() {
        let coordinator = CameraSceneRotationCoordinator()
        var requests: [UIInterfaceOrientationMask] = []
        for _ in 0..<10 {
            coordinator.update(physicalOrientation: .landscapeLeft, interfaceOrientation: .portrait,
                               isActive: true, hasPresentedController: false) { requests.append($0) }
        }
        #expect(requests == [.landscapeRight])
        coordinator.update(physicalOrientation: .landscapeRight, interfaceOrientation: .portrait,
                           isActive: true, hasPresentedController: false) { requests.append($0) }
        #expect(requests == [.landscapeRight, .landscapeLeft])
    }

    @Test func blockedRequestIsDeferredUntilCameraIsVisibleAndSceneActive() {
        let coordinator = CameraSceneRotationCoordinator()
        var requests: [UIInterfaceOrientationMask] = []
        coordinator.update(physicalOrientation: .landscapeLeft, interfaceOrientation: .portrait,
                           isActive: false, hasPresentedController: false) { requests.append($0) }
        coordinator.update(physicalOrientation: .landscapeLeft, interfaceOrientation: .portrait,
                           isActive: true, hasPresentedController: true) { requests.append($0) }
        #expect(requests.isEmpty)
        coordinator.update(physicalOrientation: .landscapeLeft, interfaceOrientation: .portrait,
                           isActive: true, hasPresentedController: false) { requests.append($0) }
        #expect(requests == [.landscapeRight])
    }

    @Test func sceneAlreadyMatchingDoesNotRequestRotation() {
        let coordinator = CameraSceneRotationCoordinator()
        var requests: [UIInterfaceOrientationMask] = []
        coordinator.update(physicalOrientation: .landscapeLeft, interfaceOrientation: .landscapeRight,
                           isActive: true, hasPresentedController: false) { requests.append($0) }
        #expect(requests.isEmpty)
    }
}
