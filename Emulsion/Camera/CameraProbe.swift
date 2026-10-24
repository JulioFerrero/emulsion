import AVFoundation

/// Asks the camera about documented and undocumented capabilities and writes the answers to
/// Documents/probe.json. Read-only: nothing here changes a setting.
enum CameraProbe {
    static func run(device: AVCaptureDevice, photoOutput: AVCapturePhotoOutput) {
        var report: [String: Any] = [:]

        var deviceInfo = read(device, [
            "ISODigitalThreshold", "focalLength", "imageControlMode", "automaticallyAdjustsImageControlMode",
            "isGlobalToneMappingSupported", "isGlobalToneMappingEnabled", "activeMaxExposureDuration",
            "activeMaxExposureDurationClientOverride", "isLowLightVideoCaptureSupported", "isLowLightVideoCaptureEnabled",
            "digitalFlashMode", "isFaceDetectionDrivenImageProcessingEnabled", "faceDrivenAEAFMode",
        ])
        deviceInfo["imageControlModesSupported"] = (0...12).filter { supports(device, "isImageControlModeSupported:", $0) }
        deviceInfo["lensAperture"] = device.lensAperture
        deviceInfo["minimumFocusDistanceMM"] = device.minimumFocusDistance
        deviceInfo["lockingFocusWithCustomLensPosition"] = device.isLockingFocusWithCustomLensPositionSupported
        deviceInfo["exposureBiasRange"] = [device.minExposureTargetBias, device.maxExposureTargetBias]
        deviceInfo["maxWhiteBalanceGain"] = device.maxWhiteBalanceGain
        report["device"] = deviceInfo

        report["activeFormat"] = describe(device.activeFormat)
        report["formats"] = device.formats.map(describe)

        var output = read(photoOutput, [
            "isDemosaicedRawSupported", "supportedDigitalFlashModes", "supportedHDRModes", "isEV0PhotoDeliverySupported",
            "isDeferredProcessingSupported", "isSemanticStyleRenderingSupported",
        ])
        output["maxBracketedCapturePhotoCount"] = photoOutput.maxBracketedCapturePhotoCount
        output["lensStabilizationDuringBracketedCapture"] = photoOutput.isLensStabilizationDuringBracketedCaptureSupported
        output["rawFormats"] = photoOutput.availableRawPhotoPixelFormatTypes.map(fourCC)
        output["codecs"] = photoOutput.availablePhotoCodecTypes.map(\.rawValue)
        output["highResolutionCapture"] = photoOutput.isHighResolutionCaptureEnabled
        output["qualityPrioritization"] = photoOutput.maxPhotoQualityPrioritization.rawValue
        report["photoOutput"] = output

        write(report, name: "probe.json")
    }

    /// One-time experiment: asks for exposures past the format's 1/3 s limit through the private path
    /// the public setter forwards to, and records what the sensor actually does. Then `restore`s.
    static func tryLongExposure(device: AVCaptureDevice, queue: DispatchQueue, restore: @escaping () -> Void) {
        var report: [String: Any] = [:]
        if let figFormat = device.activeFormat.value(forKey: "figCaptureSourceVideoFormat") as? NSObject,
           figFormat.responds(to: NSSelectorFromString("formatDictionary")),
           let dictionary = figFormat.value(forKey: "formatDictionary") as? [String: Any] {
            report["formatDictionary"] = dictionary.mapValues { "\($0)".prefix(300) }
        }
        if device.responds(to: NSSelectorFromString("fcsAttributes")),
           let attributes = device.value(forKey: "fcsAttributes") as? [String: Any] {
            report["attributes"] = attributes.mapValues { "\($0)".prefix(300) }
        }

        let selector = NSSelectorFromString("_setExposureWithMode:duration:ISO:requestID:newMaxFrameDuration:")
        guard device.responds(to: selector), let method = device.method(for: selector) else {
            report["longExposure"] = "missing"
            write(report, name: "experiment.json")
            return
        }
        typealias SetExposure = @convention(c) (AnyObject, Selector, Int64, CMTime, Float, Int32, UnsafeMutablePointer<CMTime>) -> Int32
        let setExposure = unsafeBitCast(method, to: SetExposure.self)

        var trials: [[String: Any]] = []
        func trial(_ seconds: Double, then next: @escaping () -> Void) {
            guard (try? device.lockForConfiguration()) != nil else { return next() }
            var maxFrame = CMTime.invalid
            // Mode 3 is custom exposure.
            let status = setExposure(device, selector, 3, CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                     device.activeFormat.minISO, 0, &maxFrame)
            device.unlockForConfiguration()
            queue.asyncAfter(deadline: .now() + seconds * 3 + 1) {
                trials.append([
                    "requested": seconds,
                    "status": Int(status),
                    "newMaxFrameDuration": maxFrame.isValid ? maxFrame.seconds : -1,
                    "exposureDuration": device.exposureDuration.seconds,
                    "iso": device.iso,
                    "activeMaxFrameDuration": device.activeVideoMaxFrameDuration.seconds,
                    "exposureMode": device.exposureMode.rawValue,
                ])
                next()
            }
        }
        trial(0.5) {
            trial(1) {
                restore()
                report["longExposure"] = trials
                write(report, name: "experiment.json")
            }
        }
    }

    private static func describe(_ format: AVCaptureDevice.Format) -> [String: Any] {
        var info = read(format, [
            "sensorDimensions", "rawBitDepth", "isExperimental", "isPhotoFormat", "isHighResPhotoFormat",
            "isHDRSupported", "isDigitalFlashSupported", "isSISSupported", "supportedRawPixelFormat",
            "supportedDemosaicedRawPixelFormat", "isDeepFusionSupported", "supportsHighResolutionStillImageOutput",
        ])
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        info["dimensions"] = "\(dimensions.width)x\(dimensions.height)"
        info["highResStill"] = "\(format.highResolutionStillImageDimensions.width)x\(format.highResolutionStillImageDimensions.height)"
        info["iso"] = [format.minISO, format.maxISO]
        info["exposureSeconds"] = [format.minExposureDuration.seconds, format.maxExposureDuration.seconds]
        info["fps"] = format.videoSupportedFrameRateRanges.map { [$0.minFrameRate, $0.maxFrameRate] }
        info["pixelFormat"] = fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        info["fieldOfView"] = format.videoFieldOfView
        info["maxZoom"] = format.videoMaxZoomFactor
        return info
    }

    /// KVC reads that skip selectors this iOS build doesn't have.
    private static func read(_ object: NSObject, _ keys: [String]) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in keys {
            guard object.responds(to: NSSelectorFromString(key)) else {
                values[key] = "missing"
                continue
            }
            values[key] = object.value(forKey: key).map { "\($0)" } ?? "nil"
        }
        return values
    }

    private static func supports(_ object: NSObject, _ selectorName: String, _ argument: Int64) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
        typealias Function = @convention(c) (AnyObject, Selector, Int64) -> Bool
        return unsafeBitCast(method, to: Function.self)(object, selector, argument)
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    private static func write(_ report: [String: Any], name: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: documents.appendingPathComponent(name))
    }
}
