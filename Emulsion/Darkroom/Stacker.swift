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
    /// Phase correlation on small patches: bursts move a few dozen pixels.
    private static let correlator = PhaseCorrelator(size: 256)
    /// Where the fine patches sit, as fractions of the frame: the middle, and in from each corner, so a turn of
    /// the hand or the rolling shutter's skew shows up as the corners moving differently from the middle.
    private static let anchors: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.8),
    ]
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
        // A frame on the output grid, given `warp` from reference to frame coordinates; and the same for
        // low-pass copies.
        func onGrid(_ image: CIImage, warp: CGAffineTransform) -> CIImage {
            guard zoom > 1 else {
                return image.transformed(by: warp.inverted()).cropped(to: extent)
            }
            // Output pixel p reads the frame at warp(crop origin + p / zoom).
            let m = CGAffineTransform(scaleX: 1 / zoom, y: 1 / zoom)
                .concatenating(CGAffineTransform(translationX: crop.minX, y: crop.minY))
                .concatenating(warp)
            return FilmKernels.resample.apply(
                extent: extent,
                roiCallback: { _, rect in rect.applying(m).insetBy(dx: -2, dy: -2) },
                arguments: [image.clampedToExtent(), CIVector(x: m.a, y: m.c, z: m.b, w: m.d), CIVector(x: m.tx, y: m.ty)]) ?? image
        }
        func lowOnGrid(_ low: CIImage, warp: CGAffineTransform) -> CIImage {
            low.transformed(by: warp.inverted()
                .concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
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
        let refLow = lowOnGrid(refLowFull, warp: .identity)
        let refOnGrid = zoom > 1 ? onGrid(refImage, warp: .identity) : refImage
        let refCoarse = correlator.spectrum(patch(refImage, gain: 1, scale: 0.25, context: context))
        let refFine = patches(refImage, gain: 1, at: anchors.map { anchor($0, extent) }, context: context).map(correlator.spectrum)
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
                if let (warp, patches) = correlate(frameImage, gain: gain, coarse: refCoarse, fine: refFine, context: context) {
                    aligned = onGrid(frameImage, warp: warp)
                    // The low-pass copy of the aligned frame is the low-pass copy of the frame, moved the same.
                    render(lowPass(frameImage), into: frameLowBuffer, context: context)
                    alignedLow = lowOnGrid(upsampled(image(frameLowBuffer, extent: .zero)), warp: warp)
                    let center = CGPoint(x: extent.midX, y: extent.midY)
                    let moved = center.applying(warp)
                    Timing.mark(String(format: "frame %d aligned in %.0f ms on %d patches, moved %.1f, %.1f px, turned %.2f°",
                                       i + 1, Date().timeIntervalSince(started) * 1000, patches,
                                       moved.x - center.x, moved.y - center.y, atan2(warp.b, warp.a) * 180 / .pi))
                } else {
                    if !refSmallReady {
                        render(registrationImage(refImage, gain: 1, scale: scale), into: refSmall, context: context)
                        refSmallReady = true
                    }
                    render(registrationImage(frameImage, gain: gain, scale: scale), into: frameSmall, context: context)
                    aligned = align(frameImage, small: frameSmall, to: refSmall, scale: scale, extent: extent)
                        .map { zoom > 1 ? onGrid($0, warp: .identity) : $0 }
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

    /// Where the reference's content sits in the frame, as a map from reference to frame coordinates: a coarse
    /// shift on a quarter-size patch, then sub-pixel matches at the middle and near each corner, fitted with
    /// an affine (shift, turn, scale and rolling-shutter skew). Patches on flat sky or on something moving
    /// drop out. Nil when even the coarse match is too weak to trust. Also returns how many patches it used.
    private static func correlate(_ frame: CIImage, gain: Double, coarse: PhaseCorrelator.Spectrum,
                                  fine: [PhaseCorrelator.Spectrum], context: CIContext) -> (CGAffineTransform, Int)? {
        let first = correlator.offset(of: correlator.spectrum(patch(frame, gain: gain, scale: 0.25, context: context)), from: coarse)
        guard first.strength > minimumStrength else { return nil }
        // Patch rows run top down; Core Image's y runs up.
        let shift = CGPoint(x: CGFloat(first.x) * 4, y: -CGFloat(first.y) * 4)
        // Fine patches come from the same places as the reference's, so what they measure is what's left.
        let moved = frame.transformed(by: CGAffineTransform(translationX: -shift.x, y: -shift.y))
        var matches: [(from: CGPoint, to: CGPoint)] = []
        let rects = anchors.map { anchor($0, frame.extent) }
        for (at, (samples, spectrum)) in zip(rects, zip(patches(moved, gain: gain, at: rects, context: context), fine)) {
            let second = correlator.offset(of: correlator.spectrum(samples), from: spectrum)
            if second.strength > minimumStrength, abs(second.x) < 6, abs(second.y) < 6 {
                let c = CGPoint(x: at.midX, y: at.midY)
                matches.append((c, CGPoint(x: c.x + shift.x + CGFloat(second.x), y: c.y + shift.y - CGFloat(second.y))))
            }
        }
        // Something moving through one patch disagrees with the rest: drop the worst while it's out by a pixel.
        var warp = fitAffine(matches)
        while let fitted = warp, matches.count > 3 {
            let errors = matches.map { hypot($0.from.applying(fitted).x - $0.to.x, $0.from.applying(fitted).y - $0.to.y) }
            guard let worst = errors.indices.max(by: { errors[$0] < errors[$1] }), errors[worst] > 1 else { break }
            matches.remove(at: worst)
            warp = fitAffine(matches)
        }
        // A hand turns a fraction of a degree in a burst; anything far from that is a bad fit.
        if let fitted = warp, abs(fitted.a - 1) < 0.02, abs(fitted.d - 1) < 0.02, abs(fitted.b) < 0.02, abs(fitted.c) < 0.02 {
            return (fitted, matches.count)
        }
        // Too few patches to fit a turn: shift by what they agree on, or the coarse match alone.
        let mean = matches.isEmpty ? .zero : CGPoint(
            x: matches.map { $0.to.x - $0.from.x }.reduce(0, +) / CGFloat(matches.count) - shift.x,
            y: matches.map { $0.to.y - $0.from.y }.reduce(0, +) / CGFloat(matches.count) - shift.y)
        return (CGAffineTransform(translationX: shift.x + mean.x, y: shift.y + mean.y), matches.count)
    }

    /// Least-squares affine through point matches, nil for fewer than three or for points in a line.
    private static func fitAffine(_ matches: [(from: CGPoint, to: CGPoint)]) -> CGAffineTransform? {
        guard matches.count >= 3 else { return nil }
        // Centered, so the normal equations stay well conditioned at 4000-pixel coordinates.
        let n = Double(matches.count)
        let cx = matches.map { Double($0.from.x) }.reduce(0, +) / n
        let cy = matches.map { Double($0.from.y) }.reduce(0, +) / n
        var normal = simd_double3x3()
        var u = SIMD3<Double>.zero, v = SIMD3<Double>.zero
        for m in matches {
            let p = SIMD3(Double(m.from.x) - cx, Double(m.from.y) - cy, 1)
            normal += simd_double3x3(columns: (p * p.x, p * p.y, p * p.z))
            u += p * Double(m.to.x)
            v += p * Double(m.to.y)
        }
        guard abs(normal.determinant) > 1e-6 * pow(normal[0][0] + normal[1][1], 2) else { return nil }
        let x = normal.inverse * u
        let y = normal.inverse * v
        // x' = x.x (X − cx) + x.y (Y − cy) + x.z, likewise y'.
        return CGAffineTransform(a: x.x, b: y.x, c: x.y, d: y.y,
                                 tx: x.z - x.x * cx - x.y * cy, ty: y.z - y.x * cx - y.y * cy)
    }

    /// A patch-sized rect centered at `fraction` of `extent`.
    private static func anchor(_ fraction: CGPoint, _ extent: CGRect) -> CGRect {
        let side = CGFloat(correlator.size)
        return CGRect(x: extent.minX + extent.width * fraction.x - side / 2, y: extent.minY + extent.height * fraction.y - side / 2,
                      width: side, height: side)
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

    /// Full-size patches at each of `rects`, side by side in one render: each render waits on the GPU, and on
    /// the A9 the wait costs more than the patch.
    private static func patches(_ image: CIImage, gain: Double, at rects: [CGRect], context: CIContext) -> [[Float]] {
        let side = correlator.size
        let source = registrationImage(image, gain: gain, scale: 1)
        var strip = CIImage.empty()
        for (i, rect) in rects.enumerated() {
            let origin = CGPoint(x: rect.midX.rounded() - CGFloat(side / 2), y: rect.midY.rounded() - CGFloat(side / 2))
            let tile = CGRect(origin: origin, size: CGSize(width: side, height: side))
            strip = source.cropped(to: tile)
                .transformed(by: CGAffineTransform(translationX: CGFloat(i * side) - origin.x, y: -origin.y))
                .composited(over: strip)
        }
        let width = side * rects.count
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * side)
        pixels.withUnsafeMutableBytes {
            context.render(strip, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: side), format: .RGBAf, colorSpace: nil)
        }
        var out = [[Float]](repeating: [Float](repeating: 0, count: side * side), count: rects.count)
        for i in rects.indices {
            for row in 0..<side {
                let start = row * width + i * side
                for x in 0..<side {
                    out[i][row * side + x] = pixels[start + x].y
                }
            }
        }
        return out
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
