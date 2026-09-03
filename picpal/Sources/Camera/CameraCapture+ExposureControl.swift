import AVFoundation

// MARK: - Exposure and focus control

extension CameraCapture {

    // MARK: - Tap-to-focus / tap-to-expose

    /// Sets the focus and exposure point of interest on the active capture device.
    ///
    /// - Parameter point: Normalized device coordinates (0–1 in each axis) where
    ///   (0,0) is the top-left corner of the sensor image.
    ///   Use `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)`
    ///   to convert from view coordinates before calling this method.
    public func setFocusAndExposure(at point: CGPoint) {
        guard let device = videoDevice else { return }
        try? device.lockForConfiguration()
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
            device.exposureMode = .autoExpose
        }
        device.unlockForConfiguration()
    }

    // MARK: - EV bias

    /// Sets the exposure target bias.
    ///
    /// - Parameter bias: The desired exposure compensation in EV stops.
    ///   Values outside `[device.minExposureTargetBias, device.maxExposureTargetBias]`
    ///   are clamped. Passing `0` resets the bias and clears `exposureBiasIsManual`.
    public func setExposureBias(_ bias: Float) {
        // Update the manual-EV flag before touching the device so the property
        // is always consistent even in tests where videoDevice is nil.
        exposureBiasIsManual = (bias != 0)

        guard let device = videoDevice else { return }
        let clamped = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
        try? device.lockForConfiguration()
        device.setExposureTargetBias(clamped)
        device.unlockForConfiguration()
    }
}
