import XCTest
import AVFoundation
@testable import PicPal

final class CameraConfigurationTests: XCTestCase {

    // MARK: - Default configuration

    func testDefaultPresetIs720p() {
        XCTAssertEqual(CameraConfiguration.defaultConfiguration.preset, .hd1280x720)
    }

    func testDefaultFPSIs30() {
        XCTAssertEqual(CameraConfiguration.defaultConfiguration.targetFPS, 30)
    }

    // MARK: - FPS clamping

    func testFPSBelowMinimumClampsToMinimum() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: -10)
        XCTAssertEqual(config.targetFPS, CameraConfiguration.minimumFPS)
    }

    func testFPSOfZeroClampsToMinimum() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: 0)
        XCTAssertEqual(config.targetFPS, CameraConfiguration.minimumFPS)
    }

    func testFPSAboveMaximumClampsToMaximum() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: 999)
        XCTAssertEqual(config.targetFPS, CameraConfiguration.maximumFPS)
    }

    func testFPSAtMinimumBoundaryIsAccepted() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: CameraConfiguration.minimumFPS)
        XCTAssertEqual(config.targetFPS, CameraConfiguration.minimumFPS)
    }

    func testFPSAtMaximumBoundaryIsAccepted() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: CameraConfiguration.maximumFPS)
        XCTAssertEqual(config.targetFPS, CameraConfiguration.maximumFPS)
    }

    func testFPSWithinRangeIsStoredUnchanged() {
        let config = CameraConfiguration(preset: .hd1280x720, targetFPS: 24)
        XCTAssertEqual(config.targetFPS, 24)
    }

    // MARK: - Constant sanity

    func testMinimumFPSIsPositive() {
        XCTAssertGreaterThan(CameraConfiguration.minimumFPS, 0)
    }

    func testMaximumFPSExceedsMinimum() {
        XCTAssertGreaterThan(CameraConfiguration.maximumFPS, CameraConfiguration.minimumFPS)
    }

    // MARK: - Equatable

    func testConfigurationsWithSameValuesAreEqual() {
        let a = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        let b = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        XCTAssertEqual(a, b)
    }

    func testConfigurationsWithDifferentPresetsAreNotEqual() {
        let a = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        let b = CameraConfiguration(preset: .hd1920x1080, targetFPS: 30)
        XCTAssertNotEqual(a, b)
    }

    func testConfigurationsWithDifferentFPSAreNotEqual() {
        let a = CameraConfiguration(preset: .hd1280x720, targetFPS: 24)
        let b = CameraConfiguration(preset: .hd1280x720, targetFPS: 30)
        XCTAssertNotEqual(a, b)
    }
}
