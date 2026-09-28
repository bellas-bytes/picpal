import Testing
import Foundation
import CoreMedia
import CoreVideo
import os
@testable import PicPal

struct LandmarkModelBundleTests {
    @Test("The app bundles the models required for on-device coaching",
          arguments: ["hand_landmarker", "face_landmarker"])
    func requiredModelIsBundled(name: String) throws {
        let url = try #require(Bundle.main.url(forResource: name, withExtension: "task"))
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        #expect((size ?? 0) > 0)
    }
}

// MARK: - Thread-safe container for test assertions

/// A lock-protected box used in tests to capture values from @Sendable closures
/// without violating Swift 6 strict concurrency rules.
private final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<T>
    init(_ initial: T) { lock = OSAllocatedUnfairLock(initialState: initial) }
    func set(_ value: T) { lock.withLock { $0 = value } }
    var value: T { lock.withLock { $0 } }
}

private final class LockedOptional<T: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<T?>
    init() { lock = OSAllocatedUnfairLock(initialState: nil) }
    func set(_ value: T) { lock.withLock { $0 = value } }
    var value: T? { lock.withLock { $0 } }
}

// MARK: - LandmarkProbeStats tests

struct LandmarkProbeStatsTests {

    @Test("LandmarkProbeStats.zero produces all-zero values")
    func zeroStatHasZeroValues() {
        let stats = LandmarkProbeStats.zero
        #expect(stats.bodyPoseMs  == 0)
        #expect(stats.handPoseMs  == 0)
        #expect(stats.faceMeshMs  == 0)
        #expect(stats.combinedMs  == 0)
        #expect(stats.frameCount  == 0)
    }

    @Test("LandmarkProbeStats memberwise init stores given values")
    func memberwiseInitStoresValues() {
        let stats = LandmarkProbeStats(
            bodyPoseMs:  12.5,
            handPoseMs:  18.3,
            faceMeshMs:  45.1,
            combinedMs:  75.9,
            frameCount:  42
        )
        #expect(stats.bodyPoseMs  == 12.5)
        #expect(stats.handPoseMs  == 18.3)
        #expect(stats.faceMeshMs  == 45.1)
        #expect(stats.combinedMs  == 75.9)
        #expect(stats.frameCount  == 42)
    }

    @Test("LandmarkProbeStats is Equatable — identical values compare equal")
    func equalityHoldsForIdenticalValues() {
        let a = LandmarkProbeStats(
            bodyPoseMs: 10, handPoseMs: 20, faceMeshMs: 30, combinedMs: 60, frameCount: 1
        )
        let b = LandmarkProbeStats(
            bodyPoseMs: 10, handPoseMs: 20, faceMeshMs: 30, combinedMs: 60, frameCount: 1
        )
        #expect(a == b)
    }

    @Test("LandmarkProbeStats is Equatable — differing values compare unequal")
    func equalityFailsForDifferentValues() {
        let a = LandmarkProbeStats(
            bodyPoseMs: 10, handPoseMs: 20, faceMeshMs: 30, combinedMs: 60, frameCount: 1
        )
        let b = LandmarkProbeStats(
            bodyPoseMs: 10, handPoseMs: 20, faceMeshMs: 30, combinedMs: 60, frameCount: 2
        )
        #expect(a != b)
    }
}

// MARK: - VisionLandmarkProbe tests

struct VisionLandmarkProbeTests {

    @Test("Probe initialises with isEnabled true by default")
    func defaultIsEnabled() {
        let probe = VisionLandmarkProbe { _ in }
        #expect(probe.isEnabled == true)
    }

    @Test("Probe initialises with isEnabled false when specified")
    func disabledOnInit() {
        let probe = VisionLandmarkProbe(isEnabled: false) { _ in }
        #expect(probe.isEnabled == false)
    }

    @Test("Setting isEnabled to true enables the probe")
    func enableProbe() {
        let probe = VisionLandmarkProbe(isEnabled: false) { _ in }
        probe.isEnabled = true
        #expect(probe.isEnabled == true)
    }

    @Test("Setting isEnabled to false disables the probe")
    func disableProbe() {
        let probe = VisionLandmarkProbe(isEnabled: true) { _ in }
        probe.isEnabled = false
        #expect(probe.isEnabled == false)
    }

    @Test("Stats callback path delivers correct values via test entry-point")
    func statsCallbackDeliversValues() {
        let received = LockedOptional<LandmarkProbeStats>()
        let probe = VisionLandmarkProbe { stats in received.set(stats) }

        probe.fireStatsForTesting(
            bodyPoseMs:  10.0,
            handPoseMs:  20.0,
            faceMeshMs:  40.0,
            combinedMs:  70.0,
            frameCount:  1
        )

        let result = received.value
        #expect(result?.bodyPoseMs  == 10.0)
        #expect(result?.handPoseMs  == 20.0)
        #expect(result?.faceMeshMs  == 40.0)
        #expect(result?.combinedMs  == 70.0)
        #expect(result?.frameCount  == 1)
    }

    @Test("Stats callback fires even when probe is disabled (guard is in frame callback only)")
    func disabledProbeStillFiresTestEntry() {
        // The isEnabled guard lives in cameraCapture(didOutputPixelBuffer:).
        // fireStatsForTesting bypasses that guard intentionally, confirming the
        // callback wiring is correct regardless of the enabled state.
        let count = Locked<Int>(0)
        let probe = VisionLandmarkProbe(isEnabled: false) { _ in count.set(count.value + 1) }
        probe.fireStatsForTesting(
            bodyPoseMs: 0, handPoseMs: 0, faceMeshMs: 0, combinedMs: 0, frameCount: 0
        )
        #expect(count.value == 1)
    }

    @Test("Disabled probe does not invoke onProbeStats when a frame arrives via the camera delegate")
    func disabledProbeGatesFrameDelivery() async throws {
        let callCount = Locked<Int>(0)
        let probe = VisionLandmarkProbe(isEnabled: false) { _ in
            callCount.set(callCount.value + 1)
        }

        // Synthetic 4×4 BGRA pixel buffer — CoreVideo only, no AVFoundation required.
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard let buffer = pixelBuffer else { return }

        let camera = CameraCapture()
        probe.cameraCapture(camera, didOutputPixelBuffer: buffer, timestamp: .zero)

        // Allow more than enough time for any background Vision dispatch to fire.
        try await Task.sleep(for: .milliseconds(200))

        #expect(callCount.value == 0, "disabled probe must not fire onProbeStats")
    }
}
