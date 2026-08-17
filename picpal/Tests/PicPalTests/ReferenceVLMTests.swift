import Testing
import CoreVideo
import CoreMedia
import CoreImage
import UIKit
import Foundation
import os
@testable import PicPal

// MARK: - ReferenceVLMTests

/// Unit tests for M5.5-4: two-image VLM encode path + per-reference consent gating.
///
/// All five tests must FAIL before implementation and PASS after.
///
/// `@Suite(.serialized)` prevents parallel races on `VLMSettings.shared.isOnDeviceOnly`
/// (backed by `UserDefaults.standard`).
@Suite(.serialized)
struct ReferenceVLMTests {

    // MARK: - Helpers

    /// Builds a small solid-color UIImage for deterministic encode testing.
    private func makeTestUIImage(
        width: Int = 200,
        height: Int = 150
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Decodes JPEG data and returns its (width, height) in pixels, or nil on failure.
    private func jpegDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let ci = CIImage(data: data) else { return nil }
        return (Int(ci.extent.width), Int(ci.extent.height))
    }

    private func enableCloudVLM() {
        VLMSettings.shared.isOnDeviceOnly = false
    }

    private func resetVLMSettings() {
        UserDefaults.standard.removeObject(forKey: VLMSettings.onDeviceOnlyKey)
    }

    // MARK: - Test 1

    /// `FrameEncoder.encode(pixelBuffer:referenceImage:)` must return two non-empty Data values.
    @Test("encode(pixelBuffer:referenceImage:) returns two non-empty Data")
    func encode_pixelBuffer_referenceImage_returnsTwoNonEmptyData() {
        guard let pixelBuffer = makeFilledPixelBuffer(grayValue: 128) else {
            Issue.record("Failed to create pixel buffer"); return
        }
        let refImage = makeTestUIImage()
        guard let result = FrameEncoder.encode(
            pixelBuffer: pixelBuffer, referenceImage: refImage
        ) else {
            Issue.record("encode(pixelBuffer:referenceImage:) returned nil"); return
        }
        #expect(!result.liveData.isEmpty, "liveData must be non-empty")
        #expect(!result.referenceData.isEmpty, "referenceData must be non-empty")
    }

    // MARK: - Test 2

    /// Both encoded outputs must have longest edge ≤ `FrameEncoder.maxDimension`.
    @Test("encode(pixelBuffer:referenceImage:) both outputs within targetDimension")
    func encode_pixelBuffer_referenceImage_bothWithinTargetDimension() {
        // Large pixel buffer (1920×1080) to force downscaling.
        guard let pixelBuffer = makeFilledPixelBuffer(
            grayValue: 100, width: 1920, height: 1080
        ) else {
            Issue.record("Failed to create 1920×1080 pixel buffer"); return
        }
        // Tall reference image (800×1200) to force downscaling on the reference side.
        let refImage = makeTestUIImage(width: 800, height: 1200)

        guard let result = FrameEncoder.encode(
            pixelBuffer: pixelBuffer, referenceImage: refImage
        ) else {
            Issue.record("encode(pixelBuffer:referenceImage:) returned nil"); return
        }

        if let dims = jpegDimensions(result.liveData) {
            let longest = max(dims.width, dims.height)
            #expect(longest <= FrameEncoder.maxDimension,
                    "liveData longest edge \(longest) exceeds maxDimension \(FrameEncoder.maxDimension)")
        } else {
            Issue.record("Could not decode liveData JPEG dimensions")
        }

        if let dims = jpegDimensions(result.referenceData) {
            let longest = max(dims.width, dims.height)
            #expect(longest <= FrameEncoder.maxDimension,
                    "referenceData longest edge \(longest) exceeds maxDimension \(FrameEncoder.maxDimension)")
        } else {
            Issue.record("Could not decode referenceData JPEG dimensions")
        }
    }

    // MARK: - Test 3

    /// When `referenceImage` is set (and consented), the M5 cache is bypassed:
    /// VLM client is called exactly once per gate-passing frame.
    @Test("referenceImage set + consented bypasses cache — client called per gate pass")
    func cacheBypass_whenReferenceImageSet() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = CountingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }
        let capture = CameraCapture()

        orch.referenceImage = makeTestUIImage()
        orch.referenceModeConsented = true

        guard let bufA = makeFilledPixelBuffer(grayValue: 90) else {
            Issue.record("Failed to create buffer A"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufA, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 350_000_000) // 350 ms

        #expect(client.callCount == 1, "first frame in reference mode must invoke client")

        // Different scene to pass the gate again.
        guard let bufB = makeFilledPixelBuffer(grayValue: 200) else {
            Issue.record("Failed to create buffer B"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: bufB, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 350_000_000)

        #expect(client.callCount == 2, "second reference-mode frame must invoke client again")
    }

    // MARK: - Test 4

    /// When `referenceModeConsented == false`, VLM client must NOT be called even though
    /// global cloud VLM is enabled and a reference image is set.
    @Test("referenceModeConsented false suppresses VLM call")
    func referenceModeConsented_false_suppressesVLMCall() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = CountingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }
        let capture = CameraCapture()

        orch.referenceImage = makeTestUIImage()
        orch.referenceModeConsented = false // consent withheld

        guard let buf = makeFilledPixelBuffer(grayValue: 60) else {
            Issue.record("Failed to create buffer"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 350_000_000)

        #expect(client.callCount == 0,
                "VLM client must not be called when referenceModeConsented is false")
    }

    // MARK: - Test 5

    /// When `referenceModeConsented == true`, VLM client is called exactly once per gate pass.
    @Test("referenceModeConsented true allows VLM call")
    func referenceModeConsented_true_allowsVLMCall() async {
        enableCloudVLM()
        defer { resetVLMSettings() }

        let client = CountingVLMClient()
        let gate = VLMRequestGate(cadenceSeconds: 0)
        let orch = VLMOrchestrator(client: client, gate: gate) { _ in }
        let capture = CameraCapture()

        orch.referenceImage = makeTestUIImage()
        orch.referenceModeConsented = true // consent given

        guard let buf = makeFilledPixelBuffer(grayValue: 75) else {
            Issue.record("Failed to create buffer"); return
        }
        orch.cameraCapture(capture, didOutputPixelBuffer: buf, timestamp: .zero)
        try? await Task.sleep(nanoseconds: 350_000_000)

        #expect(client.callCount == 1,
                "VLM client must be called exactly once when referenceModeConsented is true")
    }
}
