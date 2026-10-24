import AudioToolbox
import AVFoundation
import UIKit

final class CameraViewController: UIViewController {
    private let camera = CameraController()
    private let renderer = FilmRenderer()
    private lazy var darkroom = Darkroom(renderer: renderer)
    private let orientation = OrientationMonitor()
    private let defaults = UserDefaults.standard
    private let recordContext: CIContext = {
        let options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        return MTLCreateSystemDefaultDevice().map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    private let viewfinder = ViewfinderView()
    private let topShade = GradientView()
    private let masks = (0..<4).map { _ in UIView() }
    private let frameLine = UIView()
    private let reticle = UIView()
    private let rawButton = UIButton(type: .custom)
    private let formatButton = UIButton(type: .custom)
    private let focalButton = UIButton(type: .custom)
    private let speedButton = UIButton(type: .custom)
    private let captureButton = UIButton(type: .custom)
    private let focusButton = UIButton(type: .custom)
    private let filterButton = UIButton(type: .custom)
    private let mistButton = UIButton(type: .custom)
    private let ndButton = UIButton(type: .custom)
    private let focusRing = FocusRing()
    private let dial = StockDial(titles: FilmStock.all.map(\.label))
    private let shutter = ShutterButton()
    private let thumbnail = UIImageView()
    private let developRing = CAShapeLayer()
    /// Shutter to Photos, shown under the thumbnail for a moment.
    private let developTime = UILabel()
    private let topPill = GlassPill()
    private let evPill = GlassPill()
    private let exposureButton = UIButton(type: .custom)
    private let photoModeButton = UIButton(type: .custom)
    private let videoModeButton = UIButton(type: .custom)

    private var mode = CameraController.Mode.photo
    private var stockIndex = 0
    private var push = 0
    private var format = FilmFormat.leica
    private var focal = FocalLength.wide
    private var capture = CaptureMode.single
    private var keepRAW = true
    private var exposureBias: Float = 0
    private var manualExposure = false
    private var shutterIndex = ShutterSpeed.nearest(to: 1.0 / 60)
    private var meter: Float = 0
    private var manualFocus = false
    private var magnifierLatched = false
    private var filter85 = false
    private var bwFilter: BWFilter?
    private var mist = Mist.off
    private var virtualND = false
    /// Video queue only.
    private lazy var blender = FrameBlender(context: recordContext)
    private var weave = CGPoint.zero
    private var developing = 0 {
        // The darkroom shares the GPU with the viewfinder; while it works, the viewfinder runs at half rate.
        didSet {
            liveLock.lock()
            live.busy = developing > 0
            liveLock.unlock()
        }
    }
    private var skipFrame = false
    /// True from the shutter until the last frame of a burst is in.
    private var holding = false

    private var aspect = VideoAspect.hd
    private var frameRate = FrameRate.cinema
    private var shutterAngle = ShutterAngle.standard
    private var exposureHeld = false
    private var recordingStart: Date?
    private var recordingOrientation = AVCaptureVideoOrientation.landscapeRight
    private var timecodeTimer: Timer?

    private var panAxis: NSLayoutConstraint.Axis?
    private var panStart: Float = 0
    private var meterTimer: Timer?
    private var magnifierRelease: DispatchWorkItem?

    private static let pushSteps = [-1, 0, 1, 2]
    private static let amber = UIColor(red: 1, green: 0.72, blue: 0.3, alpha: 1)
    private static let red = UIColor(red: 0.93, green: 0.22, blue: 0.17, alpha: 1)
    private static let dim = UIColor.white.withAlphaComponent(0.4)

    /// What the video queue needs to render the viewfinder and record.
    private struct Live {
        var mode = CameraController.Mode.photo
        var stock: FilmStock
        var push: Int
        var focal: FocalLength
        var aspect = VideoAspect.hd
        var magnify = false
        var peaking = false
        var busy = false
        var mist = 0.0
        var outputFPS = 24
        /// The shutter's open share of each frame.
        var window = 0.5
        var virtualND = false
        var recorder: VideoRecorder?
    }

    private let liveLock = NSLock()
    private var live = Live(stock: FilmStock.all[0], push: 0, focal: .wide)

    private var stock: FilmStock { FilmStock.all[stockIndex].through(bwFilter) }

    /// Frames a second in the file; Super 8 runs at its own speed.
    private var outputFPS: Int { aspect.fixedFrameRate ?? frameRate.rawValue }
    private var ndActive: Bool { virtualND && aspect.allowsVirtualND }
    /// Frames a second from the sensor: 120 under the virtual ND, blended down to `outputFPS`.
    private var captureFPS: Int { ndActive ? 120 : outputFPS }
    private var isRecording: Bool { recordingStart != nil }

    /// The 85 filter turns daylight into tungsten light for tungsten-balanced film.
    private var filterApplies: Bool { stock.balance < 4000 }
    private var balanceTemperature: Float { filter85 && filterApplies ? 5000 : stock.balance }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        restoreSettings()
        buildViews()
        renderer.prewarm()
        darkroom.prewarm()

        camera.onFrame = { [weak self] buffer, time in self?.renderPreview(buffer, time: time) }
        camera.onShutter = { [weak self] in self?.shutterBlink() }
        camera.start { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.formatButton.setAttributedTitle(Self.text("NO CAMERA", color: .white), for: .normal)
                return
            }
            if self.mode == .video {
                self.camera.setMode(.video, fps: self.captureFPS, aspect: self.aspect) { [weak self] in
                    self?.applyCameraSettings()
                }
            } else {
                self.applyCameraSettings()
            }
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        orientation.start()
        startMeter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds
        let width = bounds.width
        let top = view.safeAreaInsets.top
        viewfinder.frame = CGRect(x: 0, y: top, width: width, height: (width * 4 / 3).rounded())
        topShade.frame = CGRect(x: 0, y: top, width: width, height: 72)

        let buttons = [rawButton, formatButton, focalButton, speedButton, captureButton]
        let column = width / CGFloat(buttons.count)
        for (i, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(i) * column, y: top + 12, width: column, height: 36)
        }

        layoutFrame()
        layoutFocus()

        let panelTop = viewfinder.frame.maxY
        let panelBottom = bounds.height - view.safeAreaInsets.bottom
        dial.frame = CGRect(x: 0, y: panelTop + 6, width: width, height: 34)
        let modeY = panelBottom - 26
        photoModeButton.frame = CGRect(x: width / 2 - 76, y: modeY, width: 72, height: 22)
        videoModeButton.frame = CGRect(x: width / 2 + 4, y: modeY, width: 72, height: 22)
        let midY = (dial.frame.maxY + modeY) / 2
        shutter.frame = CGRect(x: width / 2 - 36, y: midY - 36, width: 72, height: 72)
        thumbnail.frame = CGRect(x: 32, y: midY - 22, width: 44, height: 44)
        exposureButton.frame = CGRect(x: width - 32 - 84, y: midY - 24, width: 84, height: 48)
        developTime.frame = CGRect(x: thumbnail.frame.midX - 40, y: thumbnail.frame.maxY + 6, width: 80, height: 14)
        developRing.frame = thumbnail.frame
        developRing.path = UIBezierPath(roundedRect: thumbnail.bounds.insetBy(dx: -4, dy: -4), cornerRadius: 7).cgPath
        topPill.frame = CGRect(x: width / 2 - 90, y: top + 60, width: 180, height: 32)
        evPill.frame = CGRect(x: width / 2 - 60, y: viewfinder.frame.midY - 18, width: 120, height: 36)
    }

    /// Darkens what the format crops away and draws a frame line around what it keeps.
    /// Video draws its frame with black bars itself.
    private func layoutFrame() {
        let finder = viewfinder.frame
        let kept = mode == .video ? finder : Framing.format(finder, format)
        masks[0].frame = CGRect(x: finder.minX, y: finder.minY, width: finder.width, height: kept.minY - finder.minY)
        masks[1].frame = CGRect(x: finder.minX, y: kept.maxY, width: finder.width, height: finder.maxY - kept.maxY)
        masks[2].frame = CGRect(x: finder.minX, y: kept.minY, width: kept.minX - finder.minX, height: kept.height)
        masks[3].frame = CGRect(x: kept.maxX, y: kept.minY, width: finder.maxX - kept.maxX, height: kept.height)
        frameLine.frame = kept
        frameLine.isHidden = kept == finder
    }

    private func layoutFocus() {
        let finder = viewfinder.frame
        let ringHeight: CGFloat = 60
        focusRing.frame = CGRect(x: 0, y: finder.maxY - ringHeight, width: finder.width, height: ringHeight)
        let buttonY = manualFocus ? focusRing.frame.minY - 36 : finder.maxY - 40
        focusButton.frame = CGRect(x: 4, y: buttonY, width: 52, height: 32)
        ndButton.frame = CGRect(x: 60, y: buttonY, width: 44, height: 32)
        mistButton.frame = CGRect(x: finder.midX - 50, y: buttonY, width: 100, height: 32)
        filterButton.frame = CGRect(x: finder.width - 80, y: buttonY, width: 76, height: 32)
    }

    // MARK: - Views

    private func buildViews() {
        view.addSubview(viewfinder)

        for mask in masks {
            mask.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            mask.isUserInteractionEnabled = false
            view.addSubview(mask)
        }
        frameLine.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        frameLine.layer.borderWidth = 1
        frameLine.isUserInteractionEnabled = false
        view.addSubview(frameLine)

        topShade.colors = [UIColor.black.withAlphaComponent(0.55), .clear]
        view.addSubview(topShade)

        reticle.bounds = CGRect(x: 0, y: 0, width: 64, height: 64)
        reticle.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        reticle.layer.borderWidth = 1
        reticle.alpha = 0
        reticle.isUserInteractionEnabled = false
        viewfinder.addSubview(reticle)

        rawButton.addTarget(self, action: #selector(firstButton), for: .touchUpInside)
        formatButton.addTarget(self, action: #selector(nextFormat), for: .touchUpInside)
        focalButton.addTarget(self, action: #selector(nextFocal), for: .touchUpInside)
        speedButton.addTarget(self, action: #selector(nextPush), for: .touchUpInside)
        captureButton.addTarget(self, action: #selector(lastButton), for: .touchUpInside)
        [rawButton, formatButton, focalButton, speedButton, captureButton].forEach(view.addSubview)

        focusRing.isHidden = true
        focusRing.onChange = { [weak self] position in self?.camera.setLensPosition(position) }
        focusRing.onTurning = { [weak self] turning in self?.magnifierWhileTurning(turning) }
        view.addSubview(focusRing)

        focusButton.contentHorizontalAlignment = .left
        focusButton.addTarget(self, action: #selector(toggleFocusMode), for: .touchUpInside)
        view.addSubview(focusButton)

        filterButton.contentHorizontalAlignment = .right
        filterButton.addTarget(self, action: #selector(toggleFilter), for: .touchUpInside)
        view.addSubview(filterButton)
        mistButton.addTarget(self, action: #selector(nextMist), for: .touchUpInside)
        view.addSubview(mistButton)
        ndButton.contentHorizontalAlignment = .left
        ndButton.addTarget(self, action: #selector(toggleND), for: .touchUpInside)
        view.addSubview(ndButton)

        dial.select(stockIndex, animated: false)
        dial.onSelect = { [weak self] index in self?.selectStock(index) }
        view.addSubview(dial)

        shutter.isVideo = mode == .video
        shutter.addTarget(self, action: #selector(shutterPressed), for: .touchUpInside)
        view.addSubview(shutter)

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 4
        thumbnail.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        thumbnail.isUserInteractionEnabled = true
        thumbnail.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openPhotos)))
        view.addSubview(thumbnail)

        developRing.fillColor = nil
        developRing.strokeColor = Self.amber.cgColor
        developRing.lineWidth = 1.5
        developRing.lineCap = .round
        developRing.strokeEnd = 0
        developRing.opacity = 0
        view.layer.addSublayer(developRing)

        developTime.textAlignment = .center
        developTime.alpha = 0
        view.addSubview(developTime)

        view.addSubview(topPill)
        view.addSubview(evPill)

        exposureButton.contentHorizontalAlignment = .right
        exposureButton.titleLabel?.numberOfLines = 2
        exposureButton.titleLabel?.textAlignment = .right
        exposureButton.addTarget(self, action: #selector(toggleExposureMode), for: .touchUpInside)
        exposureButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(resetExposure(_:))))
        view.addSubview(exposureButton)

        photoModeButton.addTarget(self, action: #selector(selectPhotoMode), for: .touchUpInside)
        videoModeButton.addTarget(self, action: #selector(selectVideoMode), for: .touchUpInside)
        view.addSubview(photoModeButton)
        view.addSubview(videoModeButton)

        viewfinder.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        viewfinder.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        updateControls()
    }

    private static func text(_ string: String, color: UIColor, size: CGFloat = 13) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            .kern: 1.5,
            .foregroundColor: color,
        ])
    }

    private func updateControls() {
        let video = mode == .video
        if video {
            if let fixed = aspect.fixedFrameRate {
                rawButton.setAttributedTitle(Self.text("\(fixed)P", color: Self.dim), for: .normal)
            } else {
                rawButton.setAttributedTitle(Self.text(frameRate.label, color: frameRate == .cinema ? .white : Self.amber), for: .normal)
            }
            formatButton.setAttributedTitle(Self.text(aspect.rawValue, color: .white), for: .normal)
            let angleColor = shutterAngle == .standard ? UIColor.white : Self.amber
            captureButton.setAttributedTitle(Self.text(shutterAngle.label, color: angleColor), for: .normal)
        } else {
            rawButton.setAttributedTitle(Self.text("RAW", color: keepRAW ? .white : Self.dim), for: .normal)
            formatButton.setAttributedTitle(Self.text(format.rawValue, color: .white), for: .normal)
            let captureColor = capture == .single ? UIColor.white : Self.amber
            captureButton.setAttributedTitle(Self.text(capture.rawValue, color: captureColor), for: .normal)
        }
        focalButton.setAttributedTitle(Self.text(focal.label, color: .white), for: .normal)
        let speed = "EI \(stock.exposureIndex(push: push))"
        speedButton.setAttributedTitle(Self.text(speed, color: push == 0 ? .white : Self.amber), for: .normal)
        focusButton.setAttributedTitle(Self.text(manualFocus ? "MF" : "AF", color: manualFocus ? Self.amber : .white), for: .normal)
        // One chip on the right for whatever glass the stock takes: an 85 for tungsten, contrast filters for B&W.
        if filterApplies {
            filterButton.setAttributedTitle(Self.text("85", color: filter85 ? Self.amber : Self.dim), for: .normal)
        } else if let filter = bwFilter {
            filterButton.setAttributedTitle(Self.text(filter.rawValue, color: Self.amber), for: .normal)
        } else {
            filterButton.setAttributedTitle(Self.text("FILTER", color: Self.dim), for: .normal)
        }
        filterButton.isHidden = !filterApplies && stock.monochrome == nil
        mistButton.setAttributedTitle(Self.text(mist.label, color: mist == .off ? Self.dim : Self.amber), for: .normal)
        ndButton.setAttributedTitle(Self.text("ND", color: ndActive ? Self.amber : Self.dim), for: .normal)
        ndButton.isHidden = !video || !aspect.allowsVirtualND
        photoModeButton.setAttributedTitle(Self.text("PHOTO", color: video ? Self.dim : .white, size: 11), for: .normal)
        videoModeButton.setAttributedTitle(Self.text("VIDEO", color: video ? .white : Self.dim, size: 11), for: .normal)

        // Nothing that changes the shot's format moves during a take.
        let free = !isRecording
        for control in [rawButton, formatButton, focalButton, speedButton, captureButton, filterButton,
                        mistButton, ndButton, photoModeButton, videoModeButton] as [UIControl] {
            control.isEnabled = free
            control.alpha = free ? 1 : 0.35
        }
        dial.isUserInteractionEnabled = free
        dial.alpha = free ? 1 : 0.35
        updateExposureReadout()

        liveLock.lock()
        live.mode = mode
        live.stock = stock
        live.push = push
        live.focal = focal
        live.aspect = aspect
        live.peaking = manualFocus
        live.mist = mist.strength
        live.outputFPS = outputFPS
        live.window = Double(shutterAngle.rawValue) / 360
        live.virtualND = ndActive
        liveLock.unlock()
    }

    private func updateExposureReadout(shutter duration: Double? = nil, iso: Float? = nil) {
        let title = NSMutableAttributedString()
        if mode == .video {
            // Under the virtual ND the shutter that counts is the blend's, not the sensor's.
            let blend = shutterAngle.duration(fps: outputFPS)
            let seconds = ndActive ? blend : duration ?? blend
            // Amber when the light forced the shutter off its angle: in sun, that's an ND filter's job.
            let offAngle = abs(log2(seconds / blend)) > 0.1
            title.append(Self.text(ShutterSpeed.label(seconds), color: offAngle ? Self.amber : .white))
            let second = exposureHeld ? "AE-L" : ndActive ? "ND" : iso.map { "ISO \(Int($0.rounded()))" } ?? "AUTO"
            title.append(Self.text("\n" + second, color: exposureHeld ? Self.amber : Self.dim, size: 10))
        } else if manualExposure {
            title.append(Self.text(ShutterSpeed.label(ShutterSpeed.all[shutterIndex]), color: .white))
            let off = abs(meter) >= 0.35
            let reading = off ? String(format: "%+.1f", min(max(meter, -9.9), 9.9)) : "±0.0"
            title.append(Self.text("\n" + reading, color: off ? Self.amber : Self.dim, size: 10))
        } else {
            title.append(Self.text(evLabel(exposureBias), color: exposureBias == 0 ? .white : Self.amber))
            title.append(Self.text("\nAUTO", color: Self.dim, size: 10))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
        exposureButton.setAttributedTitle(title, for: .normal)
    }

    private func evLabel(_ ev: Float) -> String {
        ev == 0 ? "±0.0" : String(format: "%+.1f", ev)
    }

    private func applyCameraSettings() {
        camera.setFilmBalance(temperature: balanceTemperature, cast: stock.colorCast)
        if mode == .photo, manualExposure {
            // The sensor runs at the film's box speed; rating it faster just means metering for less light.
            camera.setExposure(.manual(duration: ShutterSpeed.all[shutterIndex], iso: Float(stock.iso)))
        } else {
            // Rating film faster means underexposing it; development makes the difference back up.
            camera.setExposure(.auto(bias: exposureBias - Float(push)))
        }
        if mode == .video {
            // Under the virtual ND each sensor frame stays open as long as it can; the blend sets the angle.
            camera.setShutterAngle(ndActive ? .open : shutterAngle)
        }
    }

    // MARK: - Meter

    /// Photo manual: the readout under the shutter speed is the meter, stops over or under for the rated EI.
    /// Video: the shutter and ISO the camera is riding.
    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.mode == .video {
                self.camera.readExposure { duration, iso, _ in
                    guard self.mode == .video else { return }
                    self.updateExposureReadout(shutter: duration, iso: iso)
                }
                return
            }
            guard self.manualExposure else { return }
            self.camera.readExposure { _, _, offset in
                let reading = offset + Float(self.push)
                guard abs(reading - self.meter) > 0.05 else { return }
                self.meter = reading
                self.updateExposureReadout()
            }
        }
    }

    // MARK: - Preview

    /// Runs on the video queue.
    private func renderPreview(_ buffer: CVPixelBuffer, time: CMTime) {
        let size = viewfinder.drawableSize
        guard size.width > 0 else { return }
        liveLock.lock()
        let live = self.live
        liveLock.unlock()
        if live.mode == .video {
            renderVideo(buffer, time: time, live: live, size: size)
            return
        }
        skipFrame = live.busy && !skipFrame
        if skipFrame {
            return
        }

        let full = CIImage(cvPixelBuffer: buffer).oriented(.right)
        let factor = live.magnify ? live.focal.crop * 3 : live.focal.crop
        let visible = Framing.zoom(full.extent, factor: factor)
        let scale = size.width / visible.width
        let scene = full.cropped(to: visible)
            .transformed(by: CGAffineTransform(translationX: -visible.minX, y: -visible.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var film = renderer.apply(live.stock, push: live.push, to: scene, mode: .preview, seed: Self.randomSeed(), mist: live.mist)
        if live.peaking {
            film = renderer.peaking(film: film, scene: scene)
        }
        viewfinder.display(film)
    }

    /// Video: frames arrive as the sensor reads them, landscape. While recording each one is developed at the
    /// file's size and written; the viewfinder shows exactly that frame, rotated upright and letterboxed.
    /// Under the virtual ND, sensor frames are blended first and only every finished frame goes on.
    private func renderVideo(_ buffer: CVPixelBuffer, time: CMTime, live: Live, size: CGSize) {
        let sensor = CIImage(cvPixelBuffer: buffer)
        let frame = Framing.format(Framing.zoom(sensor.extent, live.focal), ratio: live.aspect.ratio)
        let recorder = live.recorder
        let superEight = live.aspect == .superEight
        // The preview develops at the viewfinder's size, magnified straight from the sensor for focusing.
        let region = recorder == nil && live.magnify ? Framing.zoom(frame, factor: 3) : frame
        let target: CGRect
        if let recorder {
            target = CGRect(origin: .zero, size: recorder.size)
        } else {
            let fit = min(size.width / region.height, size.height / region.width)
            target = CGRect(x: 0, y: 0, width: (region.width * fit).rounded(), height: (region.height * fit).rounded())
        }
        // Super 8 is developed a little larger than its frame, so the gate can weave without showing an edge.
        let overscan: CGFloat = superEight ? 1.03 : 1
        let developedRect = CGRect(x: 0, y: 0, width: (target.width * overscan).rounded(), height: (target.height * overscan).rounded())
        var scene = Self.place(sensor, from: region, into: developedRect)
        var at = time
        if live.virtualND {
            guard let blended = blender.add(scene, at: time, fps: live.outputFPS, sensorFPS: 120, window: live.window) else { return }
            scene = blended.image
            at = blended.time
        }
        if superEight {
            // An 8 mm frame resolves about 460 lines.
            scene = scene.clampedToExtent().applyingGaussianBlur(sigma: Double(1.2 * target.width / 1440)).cropped(to: developedRect)
        }
        var developed = renderer.apply(
            live.stock, push: live.push, to: scene, mode: recorder == nil ? .preview : .full,
            seed: Self.randomSeed(), grainScale: live.aspect.grainScale, mist: live.mist)
        var reference = scene
        if superEight {
            // Film settles a little differently in the gate every frame.
            weave = CGPoint(x: weave.x * 0.8 + .random(in: -1...1) * 0.0012, y: weave.y * 0.8 + .random(in: -1...1) * 0.0018)
            let move = CGAffineTransform(
                translationX: -((developedRect.width - target.width) / 2 + weave.x * target.width),
                y: -((developedRect.height - target.height) / 2 + weave.y * target.height))
            developed = developed.transformed(by: move).cropped(to: target)
            reference = scene.transformed(by: move).cropped(to: target)
        }

        var shown = developed
        if let recorder {
            guard let recorded = recorder.append(developed, at: at) else { return }
            shown = CIImage(cvPixelBuffer: recorded, options: [.colorSpace: VideoRecorder.colorSpace])
            if live.magnify {
                // Focusing during a take: the middle of the recorded frame, enlarged.
                let middle = Framing.zoom(shown.extent, factor: 3)
                shown = shown.cropped(to: middle)
                reference = reference.cropped(to: middle)
            }
        }
        var upright = Self.fit(shown.oriented(.right), in: size)
        if live.peaking {
            upright = renderer.peaking(film: upright, scene: Self.fit(reference.oriented(.right), in: size))
        }
        upright = renderer.zebras(upright, phase: at.seconds * 40)
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        viewfinder.display(upright.composited(over: black))
    }

    /// The part of `image` inside `region`, scaled to fill `target` (origin zero).
    private static func place(_ image: CIImage, from region: CGRect, into target: CGRect) -> CIImage {
        image.cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / region.width, y: target.height / region.height))
            .cropped(to: target)
    }

    /// Scaled to fit inside `size` and centered, origin at zero.
    private static func fit(_ image: CIImage, in size: CGSize) -> CIImage {
        let e = image.extent
        let s = min(size.width / e.width, size.height / e.height)
        let x = ((size.width - e.width * s) / 2).rounded()
        let y = ((size.height - e.height * s) / 2).rounded()
        return image
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    private static func randomSeed() -> CGPoint {
        CGPoint(x: .random(in: 0..<1024), y: .random(in: 0..<1024))
    }

    /// The viewfinder blacks out like a mirror flipping up, and stays dim while a burst is exposing.
    private func shutterBlink() {
        viewfinder.alpha = 0
        UIView.animate(withDuration: 0.25) { self.viewfinder.alpha = self.holding ? 0.5 : 1 }
    }

    private func holdText(_ captured: Int, of total: Int) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: Self.text("HOLD  ", color: .white, size: 12))
        for i in 0..<total {
            let done = i < captured
            text.append(Self.text(done ? "●" : "○", color: done ? Self.amber : Self.dim, size: 12))
        }
        return text
    }

    private func finishHolding() {
        guard holding else { return }
        holding = false
        topPill.hide()
        UIView.animate(withDuration: 0.2) { self.viewfinder.alpha = 1 }
        // "Pop": a short Taptic tap the 6s can play, though it has no UIFeedbackGenerator support.
        AudioServicesPlaySystemSound(1520)
    }

    private func setDevelopProgress(_ value: Float) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        developRing.opacity = 1
        developRing.strokeEnd = CGFloat(max(value, 0.03))
        CATransaction.commit()
    }

    private func setMagnifier(_ on: Bool) {
        liveLock.lock()
        live.magnify = on
        liveLock.unlock()
    }

    private func magnifierWhileTurning(_ turning: Bool) {
        magnifierRelease?.cancel()
        if turning {
            setMagnifier(true)
            return
        }
        let release = DispatchWorkItem { [weak self] in
            guard let self, !self.magnifierLatched else { return }
            self.setMagnifier(false)
        }
        magnifierRelease = release
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: release)
    }

    // MARK: - Shutter

    @objc private func shutterPressed() {
        guard mode == .video else { return takePhoto() }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func takePhoto() {
        guard !holding, developing < 2 else { return }
        let roll = Roll(stock: stock, push: push, format: format, focal: focal, capture: capture, mist: mist, keepRAW: keepRAW)
        let frames = capture.offsets.count
        let started = Date()
        developing += 1
        thumbnail.alpha = 0.3
        Timing.begin("\(capture.rawValue) \(stock.label)")
        if frames > 1 {
            holding = true
            topPill.show(holdText(0, of: frames))
        }

        // Frames that get averaged can each be shot at a handheld speed, one over the focal length.
        let limit = capture == .stack ? 1 / Double(focal.rawValue) : nil
        camera.capture(
            orientation: orientation.current,
            offsets: capture.offsets,
            shutterLimit: limit,
            onFrame: { [weak self] count in
                guard let self, self.holding else { return }
                self.topPill.show(self.holdText(count, of: frames))
            },
            completion: { [weak self] photo in
                guard let self else { return }
                self.finishHolding()
                guard let photo else {
                    self.finishDeveloping(nil)
                    return
                }
                self.darkroom.develop(photo, roll: roll, progress: { [weak self] value in
                    self?.setDevelopProgress(value)
                }, completion: { [weak self] image in
                    self?.finishDeveloping(image)
                    if image != nil {
                        self?.showDevelopTime(Date().timeIntervalSince(started))
                    }
                })
            })
    }

    private func showDevelopTime(_ seconds: TimeInterval) {
        developTime.attributedText = Self.text(String(format: "%.1fS", seconds), color: Self.dim, size: 10)
        developTime.layer.removeAllAnimations()
        developTime.alpha = 1
        UIView.animate(withDuration: 0.6, delay: 2.5, options: []) { self.developTime.alpha = 0 }
    }

    /// The print comes up out of the dark, like in the tray.
    private func finishDeveloping(_ image: UIImage?) {
        developing -= 1
        if developing == 0 {
            setDevelopProgress(1)
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.4)
            developRing.opacity = 0
            CATransaction.setCompletionBlock { [weak self] in
                guard self?.developing == 0 else { return }
                self?.developRing.strokeEnd = 0
            }
            CATransaction.commit()
        }
        guard let image else {
            thumbnail.alpha = developing > 0 ? 0.3 : 1
            return
        }
        thumbnail.image = image
        thumbnail.alpha = 0
        UIView.animate(withDuration: 0.9, delay: 0, options: .curveEaseOut) {
            self.thumbnail.alpha = self.developing > 0 ? 0.3 : 1
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard developing == 0 else { return }
        recordingOrientation = orientation.current
        guard let recorder = VideoRecorder(
            size: aspect.size, fps: outputFPS, transform: Self.transform(for: recordingOrientation),
            audioSettings: camera.audioSettings(), context: recordContext) else { return }

        Timing.begin("VIDEO \(stock.fullLabel) \(aspect.rawValue) \(outputFPS)P \(shutterAngle.label)\(ndActive ? " ND" : "")")
        camera.lockForTake(true)
        camera.onAudio = { [weak recorder] sample in recorder?.append(audio: sample) }
        liveLock.lock()
        live.recorder = recorder
        liveLock.unlock()

        recordingStart = Date()
        shutter.isRecording = true
        updateTimecode()
        timecodeTimer = Timer.scheduledTimer(withTimeInterval: 1 / 12, repeats: true) { [weak self] _ in self?.updateTimecode() }
        updateControls()
    }

    private func stopRecording() {
        liveLock.lock()
        let recorder = live.recorder
        live.recorder = nil
        liveLock.unlock()
        camera.onAudio = nil
        camera.lockForTake(false)
        if !manualFocus {
            camera.resumeAutofocus()
        }

        timecodeTimer?.invalidate()
        recordingStart = nil
        shutter.isRecording = false
        topPill.hide()
        updateControls()
        guard let recorder else { return }

        developing += 1
        setDevelopProgress(0.5)
        let still = recorder.lastFrame.flatMap { thumbnailImage($0) }
        recorder.finish { [weak self] saved in
            Timing.mark(String(format: "saved %@  frames %d  dropped %d  thermal %d",
                               saved ? "yes" : "no", recorder.frames, recorder.dropped,
                               ProcessInfo.processInfo.thermalState.rawValue))
            self?.finishDeveloping(saved ? still : nil)
        }
    }

    private func updateTimecode() {
        guard let start = recordingStart else { return }
        let fps = outputFPS
        let frames = Int(Date().timeIntervalSince(start) * Double(fps))
        let seconds = frames / fps
        let timecode = String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frames % fps)
        let text = NSMutableAttributedString(attributedString: Self.text("● ", color: Self.red, size: 12))
        text.append(Self.text("REC  " + timecode, color: .white, size: 12))
        topPill.show(text)
    }

    /// How the recorded frames should be turned to play upright, for the way the phone was held.
    private static func transform(for orientation: AVCaptureVideoOrientation) -> CGAffineTransform {
        switch orientation {
        case .portrait: return CGAffineTransform(rotationAngle: .pi / 2)
        case .portraitUpsideDown: return CGAffineTransform(rotationAngle: -.pi / 2)
        case .landscapeLeft: return CGAffineTransform(rotationAngle: .pi)
        default: return .identity
        }
    }

    private func thumbnailImage(_ buffer: CVPixelBuffer) -> UIImage? {
        let turn: CGImagePropertyOrientation
        switch recordingOrientation {
        case .portrait: turn = .right
        case .portraitUpsideDown: turn = .left
        case .landscapeLeft: turn = .down
        default: turn = .up
        }
        let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: VideoRecorder.colorSpace]).oriented(turn)
        let small = image.transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1))
        guard let cg = recordContext.createCGImage(small, from: small.extent.integral) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: - Modes

    @objc private func selectPhotoMode() {
        switchMode(to: .photo)
    }

    @objc private func selectVideoMode() {
        switchMode(to: .video)
    }

    private func switchMode(to newMode: CameraController.Mode) {
        guard newMode != mode, !isRecording, !holding else { return }
        mode = newMode
        defaults.set(newMode == .video, forKey: "video")
        shutter.isVideo = newMode == .video
        exposureHeld = false
        UIView.animate(withDuration: 0.15) { self.viewfinder.alpha = 0 }
        camera.setMode(newMode, fps: captureFPS, aspect: aspect) { [weak self] in
            guard let self else { return }
            self.applyCameraSettings()
            UIView.animate(withDuration: 0.25, delay: 0.15, options: []) { self.viewfinder.alpha = 1 }
        }
        UIView.animate(withDuration: 0.2) { self.layoutFrame() }
        updateControls()
    }

    // MARK: - Gestures

    private func selectStock(_ index: Int) {
        stockIndex = index
        defaults.set(stock.label, forKey: "stockLabel")
        // Changing film changes the box speed, which manual exposure runs the sensor at.
        applyCameraSettings()
        updateControls()
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if manualFocus {
            magnifierLatched.toggle()
            setMagnifier(magnifierLatched)
            return
        }
        let point = gesture.location(in: viewfinder)
        camera.focus(at: devicePoint(for: point))

        reticle.center = point
        reticle.alpha = 1
        reticle.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        UIView.animate(withDuration: 0.2) { self.reticle.transform = .identity }
        UIView.animate(withDuration: 0.3, delay: 0.8, options: []) { self.reticle.alpha = 0 }
    }

    /// Maps a viewfinder point to device coordinates: landscape, home button on the right, (0,0) top left.
    /// The viewfinder shows the sensor rotated upright, so its vertical is the sensor's long side.
    private func devicePoint(for point: CGPoint) -> CGPoint {
        var shown = viewfinder.bounds
        // Shares of the sensor's long and short sides on screen.
        var long = 1 / focal.crop
        var short = 1 / focal.crop
        if mode == .video {
            shown = Framing.format(viewfinder.bounds, ratio: aspect.ratio)
            // Wider than the sensor mode crops its height; narrower (square) crops its width.
            if aspect.ratio >= aspect.sensorRatio {
                short *= aspect.sensorRatio / aspect.ratio
            } else {
                long *= aspect.ratio / aspect.sensorRatio
            }
        }
        let x = min(max((point.x - shown.minX) / shown.width, 0), 1)
        let y = min(max((point.y - shown.minY) / shown.height, 0), 1)
        return CGPoint(x: 0.5 + (y - 0.5) * long, y: 0.5 + (0.5 - x) * short)
    }

    /// Horizontal swipe changes the stock. A deliberate vertical drag sets exposure compensation
    /// (shutter speed in photo manual), in third stops, with the value shown while dragging.
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: viewfinder)
        switch gesture.state {
        case .began:
            let velocity = gesture.velocity(in: viewfinder)
            panAxis = abs(velocity.x) > abs(velocity.y) ? .horizontal : .vertical
            panStart = mode == .photo && manualExposure ? Float(shutterIndex) : exposureBias
        case .changed:
            guard panAxis == .vertical, !(isRecording && exposureHeld) else { return }
            // A dead zone first, so a touch that wanders doesn't change exposure.
            let travel = -translation.y
            guard abs(travel) > 18 else { return }
            let thirds = ((travel - copysign(18, travel)) / 36).rounded()
            if mode == .photo, manualExposure {
                // Dragging up gives more light: a longer shutter.
                let index = min(max(Int(panStart) + Int(thirds), 0), ShutterSpeed.all.count - 1)
                evPill.show(Self.text(ShutterSpeed.label(ShutterSpeed.all[index]), color: .white, size: 15))
                guard index != shutterIndex else { return }
                shutterIndex = index
                defaults.set(index, forKey: "shutter")
                applyCameraSettings()
                updateExposureReadout()
            } else {
                setExposureBias(panStart + Float(thirds) / 3)
                let color = exposureBias == 0 ? UIColor.white : Self.amber
                evPill.show(Self.text("EV " + evLabel(exposureBias), color: color, size: 15))
            }
        case .ended:
            if panAxis == .horizontal, abs(translation.x) > 40, !isRecording {
                let count = FilmStock.all.count
                let index = (stockIndex + (translation.x < 0 ? 1 : count - 1)) % count
                dial.select(index, animated: true)
                selectStock(index)
            }
            evPill.hide(after: 0.4)
            panAxis = nil
        default:
            evPill.hide(after: 0.4)
            panAxis = nil
        }
    }

    private func setExposureBias(_ ev: Float) {
        let clamped = min(max(ev, -3), 3)
        guard clamped != exposureBias else { return }
        exposureBias = clamped
        applyCameraSettings()
        updateControls()
    }

    /// Photo: auto ⇄ manual; manual starts at whatever auto was giving, converted to the film's box speed.
    /// Video: AE-L, holding exposure where it is.
    @objc private func toggleExposureMode() {
        if mode == .video {
            exposureHeld.toggle()
            camera.holdExposure(exposureHeld)
            updateExposureReadout()
            return
        }
        if manualExposure {
            manualExposure = false
            defaults.set(false, forKey: "manualExposure")
            applyCameraSettings()
            updateControls()
            return
        }
        camera.readExposure { [weak self] duration, iso, _ in
            guard let self else { return }
            self.shutterIndex = ShutterSpeed.nearest(to: duration * Double(iso) / Double(self.stock.iso))
            self.manualExposure = true
            self.defaults.set(true, forKey: "manualExposure")
            self.defaults.set(self.shutterIndex, forKey: "shutter")
            self.applyCameraSettings()
            self.updateControls()
        }
    }

    /// Long press: back to ±0; in photo manual, the shutter speed the meter asks for.
    @objc private func resetExposure(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard mode == .photo, manualExposure else {
            setExposureBias(0)
            return
        }
        let target = ShutterSpeed.all[shutterIndex] * Double(exp2(-meter))
        shutterIndex = ShutterSpeed.nearest(to: target)
        defaults.set(shutterIndex, forKey: "shutter")
        applyCameraSettings()
        updateExposureReadout()
    }

    @objc private func toggleFocusMode() {
        manualFocus.toggle()
        if manualFocus {
            // Take over from wherever autofocus left the lens, like grabbing the ring after AF.
            camera.readLensPosition { [weak self] position in
                guard let self, self.manualFocus else { return }
                self.focusRing.set(position)
                self.camera.setLensPosition(position)
            }
        } else {
            magnifierLatched = false
            setMagnifier(false)
            camera.resumeAutofocus()
        }
        focusRing.isHidden = !manualFocus
        UIView.animate(withDuration: 0.2) { self.layoutFocus() }
        updateControls()
    }

    /// The 85 for tungsten stocks; for black and white, the next contrast filter: Y2, O, R25, G, none.
    @objc private func toggleFilter() {
        if filterApplies {
            filter85.toggle()
            defaults.set(filter85, forKey: "filter85")
            applyCameraSettings()
        } else {
            let all = BWFilter.allCases
            bwFilter = bwFilter.map { all.firstIndex(of: $0)! + 1 < all.count ? all[all.firstIndex(of: $0)! + 1] : nil } ?? all[0]
            defaults.set(bwFilter?.rawValue, forKey: "bwFilter")
        }
        updateControls()
    }

    @objc private func nextMist() {
        let all = Mist.allCases
        mist = all[(all.firstIndex(of: mist)! + 1) % all.count]
        defaults.set(mist.rawValue, forKey: "mist")
        updateControls()
    }

    @objc private func toggleND() {
        virtualND.toggle()
        defaults.set(virtualND, forKey: "virtualND")
        exposureHeld = false
        UIView.animate(withDuration: 0.12) { self.viewfinder.alpha = 0 }
        camera.setMode(.video, fps: captureFPS, aspect: aspect) { [weak self] in
            guard let self else { return }
            self.applyCameraSettings()
            UIView.animate(withDuration: 0.25, delay: 0.15, options: []) { self.viewfinder.alpha = 1 }
        }
        updateControls()
    }

    // MARK: - Top row

    /// RAW in photo, frame rate in video.
    @objc private func firstButton() {
        guard mode == .video else {
            keepRAW.toggle()
            defaults.set(keepRAW, forKey: "keepRAW")
            return updateControls()
        }
        guard aspect.fixedFrameRate == nil else { return }
        let all = FrameRate.allCases
        frameRate = all[(all.firstIndex(of: frameRate)! + 1) % all.count]
        defaults.set(frameRate.rawValue, forKey: "fps")
        // Reconfiguring releases the exposure hold.
        exposureHeld = false
        camera.setMode(.video, fps: captureFPS, aspect: aspect) { [weak self] in self?.applyCameraSettings() }
        updateControls()
    }

    @objc private func nextFormat() {
        if mode == .video {
            let all = VideoAspect.allCases
            let previous = (aspect.sensorRatio, captureFPS)
            aspect = all[(all.firstIndex(of: aspect)! + 1) % all.count]
            defaults.set(aspect.rawValue, forKey: "aspect")
            if previous != (aspect.sensorRatio, captureFPS) {
                // Square, Super 8 and wide come from different sensor modes and speeds.
                exposureHeld = false
                UIView.animate(withDuration: 0.12) { self.viewfinder.alpha = 0 }
                camera.setMode(.video, fps: captureFPS, aspect: aspect) { [weak self] in
                    guard let self else { return }
                    self.applyCameraSettings()
                    UIView.animate(withDuration: 0.25, delay: 0.15, options: []) { self.viewfinder.alpha = 1 }
                }
            }
            return updateControls()
        }
        let all = FilmFormat.allCases
        format = all[(all.firstIndex(of: format)! + 1) % all.count]
        defaults.set(format.rawValue, forKey: "format")
        UIView.animate(withDuration: 0.2) { self.layoutFrame() }
        updateControls()
    }

    @objc private func nextFocal() {
        let all = FocalLength.allCases
        focal = all[(all.firstIndex(of: focal)! + 1) % all.count]
        defaults.set(focal.rawValue, forKey: "focal")
        updateControls()
    }

    @objc private func nextPush() {
        let steps = Self.pushSteps
        push = steps[((steps.firstIndex(of: push) ?? 1) + 1) % steps.count]
        defaults.set(push, forKey: "push")
        applyCameraSettings()
        updateControls()
    }

    /// Capture mode in photo, shutter angle in video.
    @objc private func lastButton() {
        if mode == .video {
            let all = ShutterAngle.allCases
            shutterAngle = all[(all.firstIndex(of: shutterAngle)! + 1) % all.count]
            defaults.set(shutterAngle.rawValue, forKey: "angle")
            applyCameraSettings()
            return updateControls()
        }
        let all = CaptureMode.allCases
        capture = all[(all.firstIndex(of: capture)! + 1) % all.count]
        defaults.set(capture.rawValue, forKey: "capture")
        updateControls()
    }

    @objc private func openPhotos() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }

    @objc private func appWillResignActive() {
        if isRecording {
            stopRecording()
        }
        darkroom.releaseMemory()
        camera.pause()
        orientation.stop()
    }

    @objc private func appDidBecomeActive() {
        camera.resume()
        orientation.start()
        darkroom.prewarm()
    }

    private func restoreSettings() {
        if let label = defaults.string(forKey: "stockLabel"), let index = FilmStock.all.firstIndex(where: { $0.label == label }) {
            stockIndex = index
        }
        if defaults.object(forKey: "keepRAW") != nil {
            keepRAW = defaults.bool(forKey: "keepRAW")
        }
        if let saved = defaults.string(forKey: "format"), let value = FilmFormat(rawValue: saved) {
            format = value
        }
        if let value = FocalLength(rawValue: defaults.integer(forKey: "focal")) {
            focal = value
        }
        if Self.pushSteps.contains(defaults.integer(forKey: "push")) {
            push = defaults.integer(forKey: "push")
        }
        if let saved = defaults.string(forKey: "capture"), let value = CaptureMode(rawValue: saved) {
            capture = value
        }
        manualExposure = defaults.bool(forKey: "manualExposure")
        if defaults.object(forKey: "shutter") != nil {
            shutterIndex = min(max(defaults.integer(forKey: "shutter"), 0), ShutterSpeed.all.count - 1)
        }
        filter85 = defaults.bool(forKey: "filter85")
        bwFilter = defaults.string(forKey: "bwFilter").flatMap(BWFilter.init(rawValue:))
        mist = Mist(rawValue: defaults.integer(forKey: "mist")) ?? .off
        virtualND = defaults.bool(forKey: "virtualND")
        mode = defaults.bool(forKey: "video") ? .video : .photo
        if let saved = defaults.string(forKey: "aspect"), let value = VideoAspect(rawValue: saved) {
            aspect = value
        }
        if let value = FrameRate(rawValue: defaults.integer(forKey: "fps")) {
            frameRate = value
        }
        if let value = ShutterAngle(rawValue: defaults.integer(forKey: "angle")) {
            shutterAngle = value
        }
    }
}

final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var colors: [UIColor] = [] {
        didSet { (layer as? CAGradientLayer)?.colors = colors.map(\.cgColor) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
