import CoreImage
import CoreVideo
import Vision
import simd

/// Merges handheld RAW frames: aligned to a reference, matched in exposure, weighted by how clean
/// and how trustworthy each frame is. Equal exposures average out noise; brackets add range.
enum Stacker {
    struct Frame {
        var image: CIImage
        /// Exposure time × ISO.
        var exposure: Double
    }

    /// Developed RAW clips a little above 1.0 in linear light.
    private static let clip: Float = 0.95
    /// How far a frame may disagree with the reference, relative to its brightness, before it's distrusted.
    private static let tolerance: Float = 0.2
    /// Blur for judging agreement: wide enough to average away noise, narrow enough to see motion.
    private static let agreementRadius = 3.0
    /// Long side of the copies Vision aligns, when correlation can't.
    private static let registrationSize: CGFloat = 1024
    /// Global shift by phase correlation. Bursts move a few dozen pixels, so small patches do.
    private static let correlator = PhaseCorrelator(size: 256)
    /// Agreement is judged on copies this much smaller: low-pass enough to ignore noise, sharp enough for motion.
    private static let lowScale: CGFloat = 0.25
    /// Below this the correlation peak isn't trusted and Vision aligns instead.
    private static let minimumStrength: Float = 0.08

    /// The result reads the shared working buffers: render it before the next merge.
    /// `progress` gets the fraction of frames merged so far.
    /// `zoom` above 1 is super-resolution: the middle 1/zoom of the frame, rebuilt at full size. Every frame is
    /// resampled onto the finer grid at its own sub-pixel offset, so the burst samples the scene at more
    /// positions than any one frame did.
    static func merge(_ frames: [Frame], reference: Int, zoom: CGFloat = 1, context: CIContext,
                      progress: (Float) -> Void) -> CIImage? {
        let ref = frames[reference]
        let extent = ref.image.extent
        let crop = Framing.zoom(extent, factor: zoom)
        // Where the zoomed grid reads a frame that sits `shift` away; and the same for low-pass copies.
        func onGrid(_ image: CIImage, shift: CGPoint) -> CIImage {
            guard zoom > 1 else {
                return image.transformed(by: CGAffineTransform(translationX: -shift.x, y: -shift.y)).cropped(to: extent)
            }
            let origin = CGPoint(x: crop.minX + shift.x, y: crop.minY + shift.y)
            return FilmKernels.resample.apply(
                extent: extent,
                roiCallback: { _, rect in
                    CGRect(x: origin.x + rect.minX / zoom - 2, y: origin.y + rect.minY / zoom - 2,
                           width: rect.width / zoom + 4, height: rect.height / zoom + 4)
                },
                arguments: [image.clampedToExtent(), CIVector(x: origin.x, y: origin.y), Float(zoom)]) ?? image
        }
        func lowOnGrid(_ low: CIImage, shift: CGPoint) -> CIImage {
            low.transformed(by: CGAffineTransform(translationX: -crop.minX - shift.x, y: -crop.minY - shift.y)
                .concatenating(CGAffineTransform(scaleX: zoom, y: zoom)))
                .cropped(to: extent)
        }
        let scale = registrationSize / max(extent.width, extent.height)
        guard let buffers = workingBuffers(for: extent.size) else { return nil }
        var target = buffers.full[0]
        var spare = buffers.full[1]
        let refBuffer = buffers.full[2]
        let frameBuffer = buffers.full[3]
        let refSmall = buffers.small[0]
        let frameSmall = buffers.small[1]
        let refLowBuffer = buffers.low[0]
        let frameLowBuffer = buffers.low[1]

        // Each RAW is demosaiced exactly once, into a buffer; alignment and merging read that.
        render(ref.image, into: refBuffer, context: context)
        let refImage = image(refBuffer, extent: extent)
        render(lowPass(refImage), into: refLowBuffer, context: context)
        let refLowFull = upsampled(image(refLowBuffer, extent: .zero))
        let refLow = lowOnGrid(refLowFull, shift: .zero)
        let refOnGrid = zoom > 1 ? onGrid(refImage, shift: .zero) : refImage
        let refCoarse = correlator.spectrum(patch(refImage, gain: 1, scale: 0.25, context: context))
        let refFine = correlator.spectrum(patch(refImage, gain: 1, scale: 1, context: context))
        var refSmallReady = false
        Timing.mark("reference developed")

        // Longer exposures carry less noise; weight them in proportion.
        let weights = frames.map { $0.exposure / ref.exposure }
        let total = weights.reduce(0, +)
        var merged = CIImage(color: .clear).cropped(to: extent)

        for (i, frame) in frames.enumerated() {
            let gain = ref.exposure / frame.exposure
            var aligned: CIImage? = refOnGrid
            var alignedLow = refLow
            if i != reference {
                render(frame.image, into: frameBuffer, context: context)
                Timing.mark("frame \(i + 1) developed")
                let frameImage = image(frameBuffer, extent: extent)
                let started = Date()
                if let shift = correlate(frameImage, gain: gain, coarse: refCoarse, fine: refFine, context: context) {
                    aligned = onGrid(frameImage, shift: shift)
                    // The low-pass copy of the aligned frame is the low-pass copy of the frame, moved the same.
                    render(lowPass(frameImage), into: frameLowBuffer, context: context)
                    alignedLow = lowOnGrid(upsampled(image(frameLowBuffer, extent: .zero)), shift: shift)
                    Timing.mark(String(format: "frame %d aligned in %.0f ms, moved %.1f, %.1f px",
                                       i + 1, Date().timeIntervalSince(started) * 1000, shift.x, shift.y))
                } else {
                    if !refSmallReady {
                        render(registrationImage(refImage, gain: 1, scale: scale), into: refSmall, context: context)
                        refSmallReady = true
                    }
                    render(registrationImage(frameImage, gain: gain, scale: scale), into: frameSmall, context: context)
                    aligned = align(frameImage, small: frameSmall, to: refSmall, scale: scale, extent: extent)
                        .map { zoom > 1 ? onGrid($0, shift: .zero) : $0 }
                    alignedLow = aligned.map(blurred) ?? refLow
                    Timing.mark("frame \(i + 1) aligned by Vision")
                }
            }
            if let aligned,
               let next = FilmKernels.accumulateFrame.apply(extent: extent, arguments: [
                   merged, aligned, refOnGrid, alignedLow, refLow,
                   Float(gain), Float(weights[i] / total), clip, tolerance,
               ]) {
                render(next, into: target, context: context)
                merged = image(target, extent: extent)
                swap(&target, &spare)
            }
            Timing.mark("frame \(i + 1) merged")
            progress(Float(i + 1) / Float(frames.count))
        }
        return FilmKernels.resolveMerge.apply(extent: extent, arguments: [merged, refOnGrid])
    }

    /// How far the frame's content sits from the reference's, in Core Image pixels: coarse on a half-size
    /// patch, then refined at full size. Nil when the match is too weak to trust.
    private static func correlate(_ frame: CIImage, gain: Double, coarse: PhaseCorrelator.Spectrum,
                                  fine: PhaseCorrelator.Spectrum, context: CIContext) -> CGPoint? {
        let first = correlator.offset(of: correlator.spectrum(patch(frame, gain: gain, scale: 0.25, context: context)), from: coarse)
        guard first.strength > minimumStrength else { return nil }
        // Patch rows run top down; Core Image's y runs up.
        var shift = CGPoint(x: CGFloat(first.x) * 4, y: -CGFloat(first.y) * 4)
        // The fine patch comes from the same place as the reference's, so what it measures is what's left.
        let moved = frame.transformed(by: CGAffineTransform(translationX: -shift.x, y: -shift.y))
        let second = correlator.offset(of: correlator.spectrum(patch(moved, gain: gain, scale: 1, at: frame.extent, context: context)), from: fine)
        if second.strength > minimumStrength, abs(second.x) < 6, abs(second.y) < 6 {
            shift.x += CGFloat(second.x)
            shift.y -= CGFloat(second.y)
        }
        return shift
    }

    /// The middle of `frame` (the image's own extent unless given) at `scale`, exposure-matched, clamped and
    /// gamma-encoded: green channel, row by row.
    private static func patch(_ image: CIImage, gain: Double, scale: CGFloat, at frame: CGRect? = nil,
                              context: CIContext) -> [Float] {
        let side = correlator.size
        let small = registrationImage(image, gain: gain, scale: scale)
        let e = (frame ?? image.extent).applying(CGAffineTransform(scaleX: scale, y: scale))
        let rect = CGRect(x: (e.midX - CGFloat(side / 2)).rounded(), y: (e.midY - CGFloat(side / 2)).rounded(),
                          width: CGFloat(side), height: CGFloat(side))
        var pixels = [SIMD4<Float>](repeating: .zero, count: side * side)
        pixels.withUnsafeMutableBytes {
            context.render(small, toBitmap: $0.baseAddress!, rowBytes: side * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
        }
        return pixels.map(\.y)
    }

    /// Warps `frame` onto the reference with a homography found on the small copies.
    private static func align(_ frame: CIImage, small: CVPixelBuffer, to reference: CVPixelBuffer,
                              scale: CGFloat, extent: CGRect) -> CIImage? {
        let request = VNHomographicImageRegistrationRequest(targetedCIImage: image(small, extent: .zero))
        let handler = VNImageRequestHandler(ciImage: image(reference, extent: .zero))
        try? handler.perform([request])
        guard let observation = request.results?.first as? VNImageHomographicAlignmentObservation else { return nil }

        // The same homography at full resolution: S⁻¹ · H · S.
        let s = Float(scale)
        let full = simd_float3x3(diagonal: SIMD3(1 / s, 1 / s, 1))
            * observation.warpTransform
            * simd_float3x3(diagonal: SIMD3(s, s, 1))
        func map(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            let v = full * SIMD3(Float(x), Float(y), 1)
            return CIVector(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
        }
        let e = frame.extent
        return frame.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": map(e.minX, e.maxY),
            "inputTopRight": map(e.maxX, e.maxY),
            "inputBottomLeft": map(e.minX, e.minY),
            "inputBottomRight": map(e.maxX, e.minY),
        ]).cropped(to: extent)
    }

    /// Quarter size, a little blurred: what the agreement test compares.
    private static func lowPass(_ image: CIImage) -> CIImage {
        let small = image.transformed(by: CGAffineTransform(scaleX: lowScale, y: lowScale))
        return small.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: small.extent)
    }

    /// A low-pass copy back at full size, smoothly interpolated.
    private static func upsampled(_ low: CIImage) -> CIImage {
        low.transformed(by: CGAffineTransform(scaleX: 1 / lowScale, y: 1 / lowScale))
    }

    private static func blurred(_ image: CIImage) -> CIImage {
        image.clampedToExtent()
            .applyingGaussianBlur(sigma: agreementRadius)
            .cropped(to: image.extent)
    }

    /// Vision wants display-like images: small, clamped, gamma-encoded.
    private static func registrationImage(_ image: CIImage, gain: Double, scale: CGFloat) -> CIImage {
        let g = CGFloat(gain)
        return image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
            ])
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIColorClamp")
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1 / 2.2])
    }

    private struct Buffers {
        var size: CGSize
        var full: [CVPixelBuffer]
        var small: [CVPixelBuffer]
        var low: [CVPixelBuffer]
    }

    /// About 400 MB at 12 MP. Allocating it is slow the first time (iOS has to push other apps out of memory),
    /// so it's kept between photos and only let go when the app leaves the screen. Darkroom queue only.
    private static var buffers: Buffers?

    private static func workingBuffers(for size: CGSize) -> Buffers? {
        if let buffers, buffers.size == size {
            return buffers
        }
        buffers = nil
        let scale = registrationSize / max(size.width, size.height)
        let small = CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        let low = CGSize(width: (size.width * lowScale).rounded(.up), height: (size.height * lowScale).rounded(.up))
        let full = (0..<4).compactMap { _ in makeBuffer(size) }
        let registration = (0..<2).compactMap { _ in makeBuffer(small, format: kCVPixelFormatType_32BGRA) }
        let lows = (0..<2).compactMap { _ in makeBuffer(low) }
        guard full.count == 4, registration.count == 2, lows.count == 2 else { return nil }
        buffers = Buffers(size: size, full: full, small: registration, low: lows)
        return buffers
    }

    static func releaseBuffers() {
        buffers = nil
    }

    private static func makeBuffer(_ size: CGSize, format: OSType = kCVPixelFormatType_64RGBAHalf) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), format, attributes as CFDictionary, &buffer)
        return buffer
    }

    /// Raw working-space values in and out: no color management on intermediate buffers.
    /// Waits for the GPU, since the next step reads what this one wrote.
    private static func render(_ image: CIImage, into buffer: CVPixelBuffer, context: CIContext) {
        let origin = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = nil
        _ = try? context.startTask(toRender: origin, to: destination).waitUntilCompleted()
    }

    private static func image(_ buffer: CVPixelBuffer, extent: CGRect) -> CIImage {
        CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
