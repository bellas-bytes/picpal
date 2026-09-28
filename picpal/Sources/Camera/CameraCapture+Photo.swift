import AVFoundation

public struct CameraHardwareStatus: Sendable {
    public let isReady: Bool
    public let zoomFactor: CGFloat
    public let minZoom: CGFloat
    public let maxZoom: CGFloat
    public let isAdjusting: Bool
    public let supportsFlash: Bool
    public var displayZoomMultiplier: CGFloat = 1
}

enum PhotoCaptureError: LocalizedError, Equatable {
    case unavailable, busy, missingData
    var errorDescription: String? {
        switch self {
        case .unavailable: "The camera is not ready. Please try again."
        case .busy: "A photo is already being captured."
        case .missingData: "The camera could not produce a photo. Please try again."
        }
    }
}

extension CameraCapture {
    public func capturePhoto(flashMode: AVCaptureDevice.FlashMode = .off) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { [self] in
                guard pendingPhoto == nil else {
                    continuation.resume(throwing: PhotoCaptureError.busy)
                    return
                }
                guard captureState == .running, captureSession.isRunning,
                      let connection = photoOutput.connection(with: .video), connection.isActive else {
                    continuation.resume(throwing: PhotoCaptureError.unavailable)
                    return
                }
                if connection.isVideoOrientationSupported { connection.videoOrientation = orientation.videoOrientation }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = cameraPosition == .front
                }
                let settings = AVCapturePhotoSettings()
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .quality
                if photoOutput.supportedFlashModes.contains(flashMode) { settings.flashMode = flashMode }
                let receiver = PhotoCaptureDelegate { [self] result in
                    sessionQueue.async { [self] in
                        pendingPhoto = nil
                        continuation.resume(with: result)
                    }
                }
                pendingPhoto = receiver
                photoOutput.capturePhoto(with: settings, delegate: receiver)
            }
        }
    }

    public func cameraStatus() async -> CameraHardwareStatus {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                let device = videoDevice
                let displayMultiplier: CGFloat
                if #available(iOS 18.0, *) { displayMultiplier = device?.displayVideoZoomFactorMultiplier ?? 1 }
                else { displayMultiplier = 1 }
                continuation.resume(returning: CameraHardwareStatus(
                    isReady: captureState == .running && captureSession.isRunning && pendingPhoto == nil,
                    zoomFactor: device?.videoZoomFactor ?? 1,
                    minZoom: device?.minAvailableVideoZoomFactor ?? 1,
                    maxZoom: min(device?.maxAvailableVideoZoomFactor ?? 1, 5),
                    isAdjusting: device.map { $0.isAdjustingFocus || $0.isAdjustingExposure || $0.isAdjustingWhiteBalance || $0.isRampingVideoZoom } ?? false,
                    supportsFlash: photoOutput.supportedFlashModes.contains(.on),
                    displayZoomMultiplier: displayMultiplier
                ))
            }
        }
    }

    /// Called only on the session queue, after installing the current camera input.
    func configurePhotoDimensions() {
        guard let dimensions = videoDevice?.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { return }
        photoOutput.maxPhotoDimensions = dimensions
    }
}

/// AVFoundation retains callbacks until final capture completion. This delegate is also
/// retained by CameraCapture, and releases its continuation only at that final callback.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var data: Data?
    private var processingError: (any Error)?
    private let completion: @Sendable (Result<Data, any Error>) -> Void

    init(completion: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        processingError = error
        data = photo.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        if let error = error ?? processingError { completion(.failure(error)) }
        else if let data { completion(.success(data)) }
        else { completion(.failure(PhotoCaptureError.missingData)) }
    }
}
