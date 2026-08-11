import Testing
import CoreVideo
import CoreMedia
import Foundation
import os
@testable import PicPal

// MARK: - Test helpers

/// Spy `CameraFrameDelegate` that records calls for assertion in tests.
final class SpyCameraFrameDelegate: CameraFrameDelegate, @unchecked Sendable {
    private let countLock = OSAllocatedUnfairLock<Int>(initialState: 0)

    var frameCallCount: Int { countLock.withLock { $0 } }

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didOutputPixelBuffer pixelBuffer: CVPixelBuffer,
        timestamp: CMTime
    ) {
        countLock.withLock { $0 += 1 }
    }

    nonisolated func cameraCapture(
        _ capture: CameraCapture,
        didChangeState state: CameraCapture.CaptureState
    ) {}
}

/// Instant `VLMClient` that returns a fixed response without delay.
struct InstantVLMClient: VLMClient {
    let response: VLMResponse

    init(text: String = "NOTHING_TO_SAY") {
        response = VLMResponse(text: text)
    }

    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        return response
    }
}

/// Counting `VLMClient` that records how many times `analyze` was called.
final class CountingVLMClient: VLMClient, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    var callCount: Int { lock.withLock { $0 } }

    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        lock.withLock { $0 += 1 }
        return VLMResponse(text: "NOTHING_TO_SAY")
    }
}

/// `VLMClient` that always throws a network-failure error.
///
/// Used to drive the offline-degradation session-disable path.
final class AlwaysFailingVLMClient: VLMClient, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)

    var callCount: Int { lock.withLock { $0 } }

    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        lock.withLock { $0 += 1 }
        throw VLMError.networkFailure("simulated offline")
    }
}

/// `VLMClient` that suspends until `unblock()` is called, then returns a fixed response.
///
/// Used to simulate a scene change between VLM request dispatch and response arrival —
/// the test calls `cameraCapture` with a different buffer between `analyze` suspending
/// and `unblock()` resuming it, so `currentSignatureLock` reflects the new scene and
/// `StaleSuppressor.evaluate` discards the stale response.
final class SuspendingVLMClient: VLMClient, @unchecked Sendable {
    private let contLock = OSAllocatedUnfairLock<CheckedContinuation<VLMResponse, Never>?>(
        initialState: nil
    )
    private let responseText: String

    init(text: String = "Move subject left") {
        self.responseText = text
    }

    /// Resume the suspended `analyze` call and return the fixed response.
    func unblock() {
        let cont = contLock.withLock { state -> CheckedContinuation<VLMResponse, Never>? in
            let c = state; state = nil; return c
        }
        cont?.resume(returning: VLMResponse(text: responseText))
    }

    func analyze(_ request: VLMRequest) async throws(VLMError) -> VLMResponse {
        await withCheckedContinuation { (cont: CheckedContinuation<VLMResponse, Never>) in
            contLock.withLock { $0 = cont }
        }
    }
}

// MARK: - Pixel buffer factory

/// Creates a `CVPixelBuffer` filled with a uniform gray value for deterministic testing.
///
/// - Parameters:
///   - grayValue: Byte value written to every pixel (0–255).
///   - width: Buffer width in pixels.
///   - height: Buffer height in pixels.
/// - Returns: A non-nil pixel buffer on success.
func makeFilledPixelBuffer(
    grayValue: UInt8,
    width: Int = 64,
    height: Int = 64
) -> CVPixelBuffer? {
    var buf: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_32BGRA,
        nil,
        &buf
    )
    guard status == kCVReturnSuccess, let pixelBuffer = buf else { return nil }

    // Fill every byte so SceneSignature.compute returns a predictable luminance.
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        memset(base, Int32(grayValue), bytesPerRow * height)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

    return pixelBuffer
}
