import CoreImage
import ImageIO
import Metal
import Photos
import UIKit
import UniformTypeIdentifiers

struct Roll {
    var stock: FilmStock
    var push: Int
    var format: FilmFormat
    var focal: FocalLength
    var capture: CaptureMode
    var mist: Mist
    var keepRAW: Bool
}

/// Develops captured photos through a film stock: prints go to Photos, negatives (DNG) to Files.
final class Darkroom {
    private static let dngType = "com.adobe.raw-image"

    private let renderer: FilmRenderer
    private let queue = DispatchQueue(label: "emulsion.darkroom", qos: .userInitiated)
    /// Darkroom queue only.
    private var isWarm = false
    private let context: CIContext

    init(renderer: FilmRenderer) {
        self.renderer = renderer
        let options: [CIContextOption: Any] = [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            context = CIContext(options: options)
        }
    }

    /// Develops a burst-sized stand-in, unseen: Core Image compiles every pipeline and iOS hands over the
    /// working memory now, instead of during the first real photo (which took three times as long).
    func prewarm() {
        queue.async {
            guard !self.isWarm else { return }
            self.isWarm = true
            autoreleasepool {
                let started = Date()
                let dng = DNG(standInWidth: 4032, height: 3024)
                let mosaic = BayerFrame(standInWidth: 4032, height: 3024, scale: 4)
                let frames = (0..<4).compactMap { _ in
                    RawDeveloper.develop(mosaic.image, dng: dng, levelScale: 4, chroma: 0).map { Stacker.Frame(image: $0, exposure: 1) }
                }
                // At 50MM, so the super-resolution resampling is compiled too.
                guard frames.count == 4, let merged = Stacker.merge(frames, reference: 0, zoom: FocalLength.normal.crop,
                                                                    context: self.context, progress: { _ in }),
                      let single = RawDeveloper.develop(mosaic.image, dng: dng, levelScale: 4, chroma: 2.5) else { return }
                // Small renders are enough to compile the rest: a stock with halation and one without.
                let crop = CGRect(x: 0, y: 0, width: 512, height: 512)
                let stacked = RawDeveloper.sharpen(RawDeveloper.reduceChroma(merged, radius: 1.5), radius: 1.2, amount: 0.7)
                for (scene, stock) in [(stacked, FilmStock.tungsten), (single, FilmStock.monoPush)] {
                    let film = self.renderer.apply(stock, push: 0, to: scene.cropped(to: crop), mode: .full, seed: .zero)
                    _ = self.context.createCGImage(film, from: crop, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                }
                Timing.mark(String(format: "darkroom warmed up in %.1fs", Date().timeIntervalSince(started)))
            }
        }
    }

    /// Gives the working memory back when the app leaves the screen.
    func releaseMemory() {
        queue.async {
            Stacker.releaseBuffers()
            self.isWarm = false
        }
    }

    /// Calls back on the main queue: `progress` from 0 to 1 as it goes, then a thumbnail, or nil if developing failed.
    func develop(_ photo: CapturedPhoto, roll: Roll, progress: @escaping (Float) -> Void, completion: @escaping (UIImage?) -> Void) {
        queue.async {
            let report: (Float) -> Void = { value in DispatchQueue.main.async { progress(value) } }
            let thumbnail = autoreleasepool { self.process(photo, roll: roll, progress: report) }
            Timing.mark("done")
            DispatchQueue.main.async { completion(thumbnail) }
        }
    }

    private func process(_ photo: CapturedPhoto, roll: Roll, progress: (Float) -> Void) -> UIImage? {
        progress(0.05)
        // The frame that kept its DNG anchors a merge: the middle of a bracket, the first of a stack.
        let order = photo.frames.indices.sorted { photo.frames[$0].exposure < photo.frames[$1].exposure }
        let reference = photo.frames.firstIndex { $0.raw != nil } ?? (order.isEmpty ? nil : order[order.count / 2])
        // Merging is most of the work for a stack; the film and the JPEG take the rest.
        guard let scene = sceneImage(from: photo, reference: reference, focal: roll.focal,
                                     progress: { progress(0.05 + $0 * 0.65) }) else {
            return nil
        }
        let metadata = reference.map { photo.frames[$0].metadata } ?? photo.metadata
        let frame = Framing.format(scene.extent, roll.format)
        let framed = scene.cropped(to: frame)
            .transformed(by: CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
        let seed = CGPoint(x: .random(in: 0..<4096), y: .random(in: 0..<4096))
        let developed = renderer.apply(roll.stock, push: roll.push, to: framed, mode: .full, seed: seed, mist: roll.mist.strength)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = context.createCGImage(developed, from: developed.extent, format: .RGBA8, colorSpace: colorSpace),
              let jpeg = jpegData(image, metadata: metadata, roll: roll) else {
            return nil
        }
        Timing.mark("printed")
        progress(0.95)
        saveToPhotos(jpeg)
        if roll.keepRAW, let reference, let raw = photo.frames[reference].raw {
            saveNegative(raw)
        }

        let thumbnailWidth: CGFloat = 132
        let ratio = CGFloat(image.height) / CGFloat(image.width)
        return UIImage(cgImage: image).preparingThumbnail(of: CGSize(width: thumbnailWidth, height: thumbnailWidth * ratio))
    }

    /// Scene-linear light, upright, as much of the frame as `focal` sees. Color balance is the camera's
    /// as-shot film balance.
    private func sceneImage(from photo: CapturedPhoto, reference: Int?, focal: FocalLength,
                            progress: (Float) -> Void) -> CIImage? {
        if let reference, let scene = developOwn(photo, reference: reference, focal: focal, progress: progress) {
            return scene
        }
        return appleScene(from: photo, reference: reference, progress: progress).map { scene in
            let crop = Framing.zoom(scene.extent, focal)
            return scene.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        }
    }

    private func appleScene(from photo: CapturedPhoto, reference: Int?, progress: (Float) -> Void) -> CIImage? {
        // Apple's RAW pipeline, if ours can't read this capture.
        Timing.mark("falling back to Core Image RAW")
        if let reference, photo.frames.count > 1, photo.frames.allSatisfy({ $0.raw != nil }) {
            // Apple writes a different baseline exposure into every DNG; frames only match by
            // shutter × ISO if they all share the reference's.
            let baseline = photo.frames[reference].raw
                .flatMap { CIRAWFilter(imageData: $0, identifierHint: Self.dngType) }?.baselineExposure
            // Stacking averages noise away itself, so each frame needs only a light touch.
            let frames = photo.frames.compactMap { frame in
                frame.raw.flatMap { developRAW($0, noiseReduction: 0.15, baseline: baseline) }
                    .map { Stacker.Frame(image: $0, exposure: frame.exposure) }
            }
            guard frames.count == photo.frames.count else { return nil }
            return Stacker.merge(frames, reference: reference, context: context, progress: progress)
        }
        if let raw = reference.flatMap({ photo.frames[$0].raw }) ?? photo.frames.first?.raw {
            // Clean the sensor's own noise so film grain replaces it rather than sitting on top.
            return developRAW(raw, noiseReduction: 0.45)
        }
        if let processed = photo.processed {
            return CIImage(data: processed, options: [.applyOrientationProperty: true])
        }
        return nil
    }

    /// Our own development, straight from the mosaics: the reference frame's DNG supplies the calibration
    /// for all of them, so a burst shares one baseline and one white balance.
    /// A burst at a longer focal length is rebuilt at full size from the hand's sub-pixel movement between
    /// frames, rather than cropped.
    private func developOwn(_ photo: CapturedPhoto, reference: Int, focal: FocalLength,
                            progress: (Float) -> Void) -> CIImage? {
        guard let raw = photo.frames[reference].raw, let dng = DNG(data: raw), dng.isRGGB else {
            Timing.mark("DNG unreadable")
            return nil
        }
        guard let bayer = photo.frames[reference].bayer,
              let scale = RawDeveloper.levelScale(bayer, matching: dng),
              photo.frames.allSatisfy({ $0.bayer?.width == dng.width && $0.bayer?.height == dng.height }) else {
            let size = photo.frames[reference].bayer.map { "\($0.width)x\($0.height)" } ?? "none"
            Timing.mark("mosaic doesn't match its DNG (\(size) vs \(dng.width)x\(dng.height))")
            return nil
        }
        Timing.mark("own development, mosaic \(bayer.width)x\(bayer.height), levels x\(scale)")
        guard photo.frames.count > 1 else {
            return RawDeveloper.develop(bayer.image, dng: dng, levelScale: scale, chroma: 2.5).map { scene in
                let crop = Framing.zoom(scene.extent, focal)
                return scene.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            }
        }
        // Stacking averages most of the noise away; what color noise is left comes off once, after the merge.
        let frames = photo.frames.compactMap { frame in
            frame.bayer.flatMap { RawDeveloper.develop($0.image, dng: dng, levelScale: scale, chroma: 0) }
                .map { Stacker.Frame(image: $0, exposure: frame.exposure) }
        }
        guard frames.count == photo.frames.count,
              let merged = Stacker.merge(frames, reference: reference, zoom: focal.crop, context: context,
                                         progress: progress) else { return nil }
        let clean = RawDeveloper.reduceChroma(merged, radius: 1.5 * Double(focal.crop))
        // Resampling onto the finer grid softens a little; the burst's extra detail is under it.
        return focal == .wide ? clean : RawDeveloper.sharpen(clean, radius: 1.2, amount: 0.7)
    }

    private func developRAW(_ raw: Data, noiseReduction: Float, baseline: Float? = nil) -> CIImage? {
        guard let filter = CIRAWFilter(imageData: raw, identifierHint: Self.dngType) else { return nil }
        if let baseline {
            filter.baselineExposure = baseline
        }
        // No tone curve and no local tone mapping: the film curve does all the tone work.
        filter.boostAmount = 0
        if filter.isLocalToneMapSupported {
            filter.localToneMapAmount = 0
        }
        if filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = noiseReduction
        }
        if filter.isSharpnessSupported {
            filter.sharpnessAmount = 0.2
        }
        return filter.outputImage
    }

    private func jpegData(_ image: CGImage, metadata: [String: Any], roll: Roll) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }

        var properties = metadata
        properties.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        // Pixels are already upright.
        properties[kCGImagePropertyOrientation as String] = 1

        var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation as String] = 1
        tiff[kCGImagePropertyTIFFSoftware as String] = "Emulsion"
        properties[kCGImagePropertyTIFFDictionary as String] = tiff

        var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
        exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
        exif[kCGImagePropertyExifUserComment as String] =
            // EXIF comments are ASCII.
            "\(roll.stock.fullLabel) EI \(roll.stock.exposureIndex(push: roll.push)) \(roll.format.rawValue) \(roll.focal.label) \(roll.capture.rawValue)\(roll.mist == .off ? "" : " " + roll.mist.label)"
                .replacingOccurrences(of: "×", with: "x")
        exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = roll.focal.rawValue
        properties[kCGImagePropertyExifDictionary as String] = exif
        properties[kCGImageDestinationLossyCompressionQuality as String] = 0.92

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private func saveToPhotos(_ jpeg: Data) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
            }, completionHandler: nil)
        }
    }

    /// DNGs live in Files › On My iPhone › Emulsion › Negatives.
    private func saveNegative(_ raw: Data) {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("Negatives", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = folder.appendingPathComponent("EMU-\(formatter.string(from: Date())).dng")
        try? raw.write(to: url)
    }
}
