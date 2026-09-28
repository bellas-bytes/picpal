import AVFoundation

extension CameraCapture {
    public func setFocusAndExposure(at point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        mutateDevice { device in
            let point = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = point
                device.exposureMode = .autoExpose
            }
        }
    }

    /// Meters and continuously focuses on a stable subject in sensor coordinates.
    /// Caller controls update cadence and suspends tracking after a manual focus tap.
    /// Existing exposure compensation is preserved.
    public func trackSubject(at sensorPoint: CGPoint) {
        guard sensorPoint.x.isFinite, sensorPoint.y.isFinite else { return }
        mutateDevice { device in
            let point = CGPoint(
                x: min(1, max(0, sensorPoint.x)),
                y: min(1, max(0, sensorPoint.y))
            )
            if device.isFocusPointOfInterestSupported,
               device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    public func setExposureBias(_ bias: Float) {
        guard bias.isFinite else { return }
        exposureBiasIsManual = bias != 0
        mutateDevice { device in
            device.setExposureTargetBias(max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias)))
        }
    }

    public func setZoom(_ factor: CGFloat) {
        guard factor.isFinite else { return }
        mutateDevice { device in
            let target = max(device.minAvailableVideoZoomFactor, min(factor, min(device.maxAvailableVideoZoomFactor, 5)))
            device.ramp(toVideoZoomFactor: target, withRate: 2)
        }
    }

    public func enableAutomaticAdjustments() {
        mutateDevice { device in
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
    }

    /// Configuration locking and every hardware mutation stay on the session queue.
    private func mutateDevice(_ mutation: @escaping @Sendable (AVCaptureDevice) -> Void) {
        sessionQueue.async { [self] in
            guard pendingPhoto == nil, let device = videoDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                mutation(device)
            } catch {
                // A failed device lock must never be followed by mutations or unlock.
            }
        }
    }
}
