import Testing
import AVFoundation
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
