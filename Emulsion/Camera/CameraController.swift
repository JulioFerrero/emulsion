import AVFoundation

struct CapturedPhoto {
    struct Frame {
        /// The DNG: kept for the frame that becomes the negative; the others only need their mosaic.
        var raw: Data?
        var bayer: BayerFrame?
        /// Exposure time × ISO, for matching frames to each other.
        var exposure: Double
        var metadata: [String: Any]
    }

    var frames: [Frame] = []
    var processed: Data?
    var metadata: [String: Any] = [:]
}

enum ExposureSetting: Equatable {
    case auto(bias: Float)
    case manual(duration: Double, iso: Float)
}

final class CameraController: NSObject {
    enum Mode {
        case photo
        case video
    }

    /// Called on the video queue for every viewfinder frame, with its capture time.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Called on the audio queue for every buffer of microphone sound, in video mode.
    var onAudio: ((CMSampleBuffer) -> Void)?
    /// Called on the main queue the moment the shutter fires.
    var onShutter: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "emulsion.session")
    private let videoQueue = DispatchQueue(label: "emulsion.video", qos: .userInteractive)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "emulsion.audio")
    private var audioInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var mode = Mode.photo
    private var fps = 24
    private var shutterAngle = ShutterAngle.standard
    /// The operator's exposure lock, before a take.
    private var exposureHeld = false
    /// Exposure, white balance and focus frozen for the length of a take.
    private var takeLocked = false
    private var captures: [Int64: PhotoCapture] = [:]
    private var exposure = ExposureSetting.auto(bias: 0)
    private var balance: (temperature: Float, cast: Float) = (5500, 1)
    private var logGains: SIMD3<Float>?
    private var balanceTimer: DispatchSourceTimer?

    func start(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            self.sessionQueue.async {
                let configured = self.configure()
                if configured {
                    self.session.startRunning()
                }
                DispatchQueue.main.async { completion(configured) }
            }
        }
    }

    func resume() {
        sessionQueue.async {
            if self.device != nil, !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func pause() {
        sessionQueue.async {
            self.session.stopRunning()
        }
    }

    // MARK: - Focus

    /// `point` is in device coordinates: (0,0) top left with the home button on the right.
    func focus(at point: CGPoint) {
        withDevice { device in
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                // Video meters through its own loop in custom mode.
                if case .auto = self.exposure, self.mode == .photo {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    /// Manual focus: 0 is the lens's closest focus (10 cm on the 6s), 1 the far end of its travel.
    func setLensPosition(_ position: Float) {
        withDevice { device in
            guard device.isFocusModeSupported(.locked) else { return }
            device.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
        }
    }

    /// Where autofocus has put the lens, on the main queue.
    func readLensPosition(_ completion: @escaping (Float) -> Void) {
        sessionQueue.async {
            guard let position = self.device?.lensPosition else { return }
            DispatchQueue.main.async { completion(position) }
        }
    }

    func resumeAutofocus() {
        resetFocus()
    }

    // MARK: - Exposure

    func setExposure(_ setting: ExposureSetting) {
        sessionQueue.async {
            self.exposure = setting
            self.applyExposure()
        }
    }

    /// Current shutter, ISO, and how far that is from what the meter wants (stops), on the main queue.
    func readExposure(_ completion: @escaping (_ duration: Double, _ iso: Float, _ offset: Float) -> Void) {
        sessionQueue.async {
            guard let device = self.device else { return }
            let reading = (device.exposureDuration.seconds, device.iso, device.exposureTargetOffset)
            DispatchQueue.main.async { completion(reading.0, reading.1, reading.2) }
        }
    }

    private func applyExposure() {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        switch exposure {
        case .auto(let bias):
            if mode == .photo, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias),
                                         completionHandler: nil)
        case .manual(let duration, let iso):
            let (time, gain) = clampedExposure(duration: duration, iso: iso, device: device)
            device.setExposureModeCustom(duration: time, iso: gain, completionHandler: nil)
            // Bias still steers the meter reading in custom mode; keep it neutral.
            device.setExposureTargetBias(0, completionHandler: nil)
        }
    }

    /// Fits a shutter/ISO pair into the format's limits, trading ISO for time when the shutter runs out.
    private func clampedExposure(duration: Double, iso: Float, device: AVCaptureDevice) -> (CMTime, Float) {
        let format = device.activeFormat
        let time = min(max(duration, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
        let gain = min(max(iso * Float(duration / time), format.minISO), format.maxISO)
        return (CMTime(seconds: time, preferredTimescale: 1_000_000), gain)
    }

    // MARK: - White balance

    /// Balances like film: `cast` 1 keeps the light's full color relative to the emulsion's balance,
    /// 0 neutralizes it completely, in between is a lab's partial correction when printing.
    func setFilmBalance(temperature: Float, cast: Float) {
        sessionQueue.async {
            self.balance = (temperature, cast)
            self.logGains = nil
            self.updateWhiteBalance()
        }
    }

    /// Runs on the session queue, four times a second, so partial correction follows the scene's light.
    /// Never during a take: on a cinema camera the white balance doesn't move by itself.
    private func updateWhiteBalance() {
        guard !takeLocked, let device, device.isWhiteBalanceModeSupported(.locked) else { return }
        func log3(_ g: AVCaptureDevice.WhiteBalanceGains) -> SIMD3<Float> {
            SIMD3(log(g.redGain), log(g.greenGain), log(g.blueGain))
        }
        let filmBalance = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: balance.temperature, tint: 0)
        let film = log3(device.deviceWhiteBalanceGains(for: filmBalance))
        let neutral = log3(device.grayWorldDeviceWhiteBalanceGains)
        var target = neutral + (film - neutral) * balance.cast
        if let current = logGains {
            target = current + (target - current) * 0.2
        }
        logGains = target

        // Device gains must sit between 1 and the maximum.
        let lowest = min(target.x, target.y, target.z)
        let maxGain = device.maxWhiteBalanceGain
        let gains = AVCaptureDevice.WhiteBalanceGains(
            redGain: min(exp(target.x - lowest), maxGain),
            greenGain: min(exp(target.y - lowest), maxGain),
            blueGain: min(exp(target.z - lowest), maxGain))
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        device.unlockForConfiguration()
    }

    // MARK: - Capture

    /// Captures one Bayer RAW per entry in `offsets` (stops relative to the current exposure).
    /// `shutterLimit` caps auto exposure's shutter for frames that will be averaged, trading it for ISO.
    /// Falls back to a single JPEG when the camera has no RAW.
    /// `onFrame` gets the number of frames captured so far; both callbacks run on the main queue.
    func capture(
        orientation: AVCaptureVideoOrientation,
        offsets: [Float],
        shutterLimit: Double? = nil,
        onFrame: @escaping (Int) -> Void = { _ in },
        completion: @escaping (CapturedPhoto?) -> Void
    ) {
        sessionQueue.async {
            guard let device = self.device else {
                completion(nil)
                return
            }
            let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes
                .first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
            let settings: AVCapturePhotoSettings
            if let rawFormat, offsets.count > 1 {
                let count = min(offsets.count, self.photoOutput.maxBracketedCapturePhotoCount)
                let brackets = offsets.prefix(count).map { self.bracket($0, shutterLimit: shutterLimit, device: device) }
                settings = AVCapturePhotoBracketSettings(rawPixelFormatType: rawFormat, processedFormat: nil,
                                                         bracketedSettings: Array(brackets))
            } else if let rawFormat {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.isHighResolutionPhotoEnabled = true
            }
            if let connection = self.photoOutput.connection(with: .video), connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }

            let id = settings.uniqueID
            // The unbracketed frame anchors a merge and becomes the negative.
            let reference = offsets.indices.min { abs(offsets[$0]) < abs(offsets[$1]) } ?? 0
            let capture = PhotoCapture(
                reference: reference,
                onShutter: { [weak self] in
                    Timing.mark("shutter open")
                    DispatchQueue.main.async { self?.onShutter?() }
                },
                onFrame: { count in
                    Timing.mark("frame \(count) captured")
                    DispatchQueue.main.async { onFrame(count) }
                },
                completion: { [weak self] photo in
                    self?.sessionQueue.async { self?.captures[id] = nil }
                    DispatchQueue.main.async { completion(photo) }
                })
            self.captures[id] = capture
            self.photoOutput.capturePhoto(with: settings, delegate: capture)
        }
    }

    private func bracket(_ offset: Float, shutterLimit: Double?, device: AVCaptureDevice) -> AVCaptureBracketedStillImageSettings {
        switch exposure {
        case .auto where shutterLimit != nil:
            // What auto exposure is giving now, bias included, with the shutter held short enough to be sharp
            // handheld; the stack takes the extra noise of the higher ISO back out.
            let metered = device.exposureDuration.seconds * pow(2, Double(offset))
            let duration = min(metered, shutterLimit ?? metered)
            let (time, gain) = clampedExposure(duration: duration, iso: device.iso * Float(metered / duration), device: device)
            return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(exposureDuration: time, iso: gain)
        case .auto(let bias):
            let target = min(max(bias + offset, device.minExposureTargetBias), device.maxExposureTargetBias)
            return AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: target)
        case .manual(let duration, let iso):
            let (time, gain) = clampedExposure(duration: duration * pow(2, Double(offset)), iso: iso, device: device)
            return AVCaptureManualExposureBracketedStillImageSettings.manualExposureSettings(exposureDuration: time, iso: gain)
        }
    }

    // MARK: - Video

    /// Photo: the full-resolution RAW format. Video: the largest sensor mode of the aspect's shape that
    /// streams at the frame rate, with sound; oversampling it down is cleaner and less over-sharpened
    /// than the sensor's own small modes.
    func setMode(_ mode: Mode, fps: Int, aspect: VideoAspect, completion: @escaping () -> Void) {
        let configure = { (withSound: Bool) in
            self.sessionQueue.async {
                self.session.beginConfiguration()
                if mode == .video {
                    if withSound {
                        self.addAudio()
                    }
                    self.selectVideoFormat(fps: fps, shape: aspect.sensorRatio)
                } else {
                    self.removeAudio()
                    self.session.sessionPreset = .photo
                }
                if let connection = self.videoOutput.connection(with: .video), connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = mode == .video ? .cinematic : .off
                }
                // Above 60 fps frames are blended by timestamp, so they queue instead of being dropped when late.
                self.videoOutput.alwaysDiscardsLateVideoFrames = mode == .photo || fps <= 60
                self.session.commitConfiguration()
                if mode == .video {
                    // Committing can reset the frame rate to the format's default; set it again.
                    self.setFrameRate(fps)
                }
                self.mode = mode
                self.fps = fps
                self.exposureHeld = false
                self.takeLocked = false
                self.applyExposure()
                DispatchQueue.main.async(execute: completion)
            }
        }
        if mode == .video {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: configure)
        } else {
            configure(false)
        }
    }

    func setShutterAngle(_ angle: ShutterAngle) {
        sessionQueue.async {
            self.shutterAngle = angle
            self.updateVideoExposure(force: true)
        }
    }

    /// AE-L: exposure stays where it is until released.
    func holdExposure(_ held: Bool) {
        sessionQueue.async {
            self.exposureHeld = held
        }
    }

    /// For the length of a take, nothing moves by itself: exposure, white balance and autofocus all hold.
    func lockForTake(_ locked: Bool) {
        sessionQueue.async {
            self.takeLocked = locked
            guard locked, let device = self.device, device.focusMode == .continuousAutoFocus,
                  device.isFocusModeSupported(.locked), (try? device.lockForConfiguration()) != nil else { return }
            device.focusMode = .locked
            device.unlockForConfiguration()
        }
    }

    /// Settings for writing the microphone's sound, or nil when there's no microphone.
    func audioSettings() -> [String: Any]? {
        sessionQueue.sync {
            audioInput == nil ? nil : audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
        }
    }

    /// Shutter priority, the way a cinema camera is run: the shutter holds its angle and ISO rides the light.
    /// The shutter only moves when ISO runs out: faster in bright sun (an ND filter's job), up to 360° in the dark.
    private func updateVideoExposure(force: Bool = false) {
        guard mode == .video, !takeLocked, !exposureHeld || force, case .auto = exposure,
              let device, device.isExposureModeSupported(.custom) else { return }
        let format = device.activeFormat
        let duration = device.exposureDuration.seconds
        let iso = Double(device.iso)
        let offset = Double(device.exposureTargetOffset)
        // Close most of the gap each tick: fast enough to follow, slow enough not to hunt.
        // Held, the exposure stays put and only its split between shutter and ISO changes.
        let needed = duration * iso * (exposureHeld ? 1 : exp2(-offset * 0.7))
        let target = shutterAngle.duration(fps: fps)
        var newDuration = target
        var newISO = needed / target
        if newISO < Double(format.minISO) {
            newISO = Double(format.minISO)
            newDuration = max(needed / newISO, format.minExposureDuration.seconds)
        } else if newISO > Double(format.maxISO) {
            newISO = Double(format.maxISO)
            newDuration = min(needed / newISO, 1 / Double(fps))
        }
        let change = abs(log2(newDuration * newISO / (duration * iso)))
        guard force || change > 0.05 || device.exposureMode != .custom || abs(log2(newDuration / duration)) > 0.05,
              (try? device.lockForConfiguration()) != nil else { return }
        device.setExposureModeCustom(
            duration: CMTime(seconds: newDuration, preferredTimescale: 1_000_000), iso: Float(newISO), completionHandler: nil)
        device.unlockForConfiguration()
    }

    /// `shape` is the sensor mode's width over height. Modes above 8 MP are left out: 12 MP at 24 fps is
    /// more than the A9 needs to stream for a 1440 or 1920 frame.
    private func selectVideoFormat(fps: Int, shape: CGFloat) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let rate = Double(fps)
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CMFormatDescriptionGetMediaSubType(format.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                && abs(CGFloat(size.width) / CGFloat(size.height) - shape) < 0.01
                && Int(size.width) * Int(size.height) <= 8_400_000
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= rate && rate <= $0.maxFrameRate }
        }
        guard let best = candidates.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width
                < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else { return }
        device.activeFormat = best
        let frame = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = frame
        device.activeVideoMaxFrameDuration = frame
    }

    private func setFrameRate(_ fps: Int) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        let frame = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMinFrameDuration = frame
        device.activeVideoMaxFrameDuration = frame
        device.unlockForConfiguration()
    }

    private func addAudio() {
        guard audioInput == nil, let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone), session.canAddInput(input) else { return }
        // Measurement mode turns off the automatic gain that makes phone audio pump with every sound.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
        try? audioSession.setActive(true)
        session.addInput(input)
        audioInput = input
        if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            session.addOutput(audioOutput)
        }
    }

    private func removeAudio() {
        guard let audioInput else { return }
        session.removeInput(audioInput)
        self.audioInput = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Setup

    private func configure() -> Bool {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return false
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // Video sets up the audio session itself, without automatic gain.
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
            return false
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        photoOutput.isHighResolutionCaptureEnabled = true

        // The sensor's own YCbCr: no conversion pass, which matters at 4K.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        session.addOutput(videoOutput)

        self.device = device
        if (try? device.lockForConfiguration()) != nil {
            device.isSubjectAreaChangeMonitoringEnabled = true
            // Meter the scene like a camera, not a face like a selfie app.
            if #available(iOS 15.4, *) {
                device.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
                device.isFaceDrivenAutoExposureEnabled = false
            }
            device.unlockForConfiguration()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(subjectAreaDidChange),
            name: .AVCaptureDeviceSubjectAreaDidChange, object: device)
        resetFocus()

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.updateWhiteBalance()
            self?.updateVideoExposure()
        }
        timer.resume()
        balanceTimer = timer

        CameraProbe.run(device: device, photoOutput: photoOutput)
        let experiment = "experiment.longExposure.1"
        if !UserDefaults.standard.bool(forKey: experiment) {
            UserDefaults.standard.set(true, forKey: experiment)
            sessionQueue.asyncAfter(deadline: .now() + 2) {
                CameraProbe.tryLongExposure(device: device, queue: self.sessionQueue) { [weak self] in
                    self?.applyExposure()
                }
            }
        }
        return true
    }

    @objc private func subjectAreaDidChange() {
        sessionQueue.async {
            // Manual focus stays where it was put, and nothing refocuses by itself during a take.
            guard !self.takeLocked, let device = self.device, device.focusMode != .locked else { return }
            self.resetFocus()
        }
    }

    private func resetFocus() {
        withDevice { device in
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = center
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = center
                if case .auto = self.exposure, self.mode == .photo, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
        }
    }

    private func withDevice(_ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            body(device)
            device.unlockForConfiguration()
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            onAudio?(sampleBuffer)
            return
        }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(buffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

private final class PhotoCapture: NSObject, AVCapturePhotoCaptureDelegate {
    private var photo = CapturedPhoto()
    private let reference: Int
    private let onShutter: () -> Void
    private let onFrame: (Int) -> Void
    private let completion: (CapturedPhoto?) -> Void

    init(reference: Int, onShutter: @escaping () -> Void, onFrame: @escaping (Int) -> Void,
         completion: @escaping (CapturedPhoto?) -> Void) {
        self.reference = reference
        self.onShutter = onShutter
        self.onFrame = onFrame
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onShutter()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else { return }
        if photo.isRawPhoto {
            let bayer = photo.pixelBuffer.flatMap(BayerFrame.init(copying:))
            // Writing a DNG compresses 12 MP on the CPU; only the negative needs one, unless the mosaic is missing.
            let dng = photo.photoCount - 1 == reference || bayer == nil ? photo.fileDataRepresentation() : nil
            guard bayer != nil || dng != nil else { return }
            let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
            let time = exif[kCGImagePropertyExifExposureTime as String] as? Double ?? 1
            let iso = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Double])?.first ?? 100
            self.photo.frames.append(.init(raw: dng, bayer: bayer, exposure: time * iso, metadata: photo.metadata))
            onFrame(self.photo.frames.count)
        } else if let data = photo.fileDataRepresentation() {
            self.photo.processed = data
        }
        if self.photo.metadata.isEmpty {
            self.photo.metadata = photo.metadata
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        completion(photo.frames.isEmpty && photo.processed == nil ? nil : photo)
    }
}
