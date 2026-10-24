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
    /// Phase correlation on small patches: bursts move a few dozen pixels. The whole frame's shift at quarter
    /// size; each anchor's at half size, band-limited against noise.
    private static let correlator = PhaseCorrelator(size: 256)
    private static let anchorCorrelator = PhaseCorrelator(size: 256, bandwidth: 16)
    /// Lucas–Kanade patches: 256 pixels with room to move, blurred so noise doesn't steer them. Noise in the
    /// gradients shortens every step; at high ISO with less blur than this the corners never settled.
    private static let fineMargin = 8
    private static let fineSide = 256 + 2 * fineMargin
    private static let fineBlur = 3.0
    /// Where the patches sit, as fractions of the frame: the middle, and in from each corner, so a turn of
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
        let centers = anchorCenters(extent)
        let refTiles = tiles([Tile(image: refImage, gain: 1, scale: 0.25, center: middle(extent))]
            + centers.map { Tile(image: refImage, gain: 1, scale: 0.5, center: $0) }, side: correlator.size, context: context)
        let refCoarse = correlator.spectrum(refTiles[0])
        let refAnchors = refTiles.dropFirst().map(anchorCorrelator.spectrum)
        let refFine = tiles(centers.map { Tile(image: refImage, gain: 1, scale: 1, center: $0, blur: fineBlur) },
                            side: fineSide, context: context)
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
                if let (warp, patches) = correlate(frameImage, gain: gain, coarse: refCoarse, anchors: refAnchors,
                                                   fine: refFine, context: context) {
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

    private struct Match {
        var from: CGPoint
        var to: CGPoint
        /// Inverse covariance of `to`, per square pixel: a patch of vertical curtain folds pins down x and
        /// says little about y.
        var information: simd_double2x2
    }

    /// Where the reference's content sits in the frame, as a map from reference to frame coordinates.
    /// Each anchor patch is found on its own at half size, so a turn of the hand that moves the corners
    /// differently from the middle is still caught, then refined to a fraction of a pixel by Lucas–Kanade at
    /// full size. Four or more matches give an affine (shift, turn, scale, rolling-shutter skew); fewer, the
    /// middle's shift. Nil when nothing matches. Also returns how many patches it used.
    private static func correlate(_ frame: CIImage, gain: Double, coarse: PhaseCorrelator.Spectrum,
                                  anchors refAnchors: [PhaseCorrelator.Spectrum], fine refFine: [[Float]],
                                  context: CIContext) -> (CGAffineTransform, Int)? {
        let centers = anchorCenters(frame.extent)
        let first = tiles([Tile(image: frame, gain: gain, scale: 0.25, center: middle(frame.extent))]
            + centers.map { Tile(image: frame, gain: gain, scale: 0.5, center: $0) }, side: correlator.size, context: context)
        // Patch rows run top down; Core Image's y runs up.
        let global = correlator.offset(of: correlator.spectrum(first[0]), from: coarse)
        let shift: CGPoint? = global.strength > minimumStrength ? CGPoint(x: CGFloat(global.x) * 4, y: -CGFloat(global.y) * 4) : nil
        // Each anchor's own coarse match, unless it's weak or far from the frame's: then the frame's.
        let starts: [CGPoint?] = centers.indices.map { i in
            let m = anchorCorrelator.offset(of: anchorCorrelator.spectrum(first[i + 1]), from: refAnchors[i])
            let own = CGPoint(x: CGFloat(m.x) * 2, y: -CGFloat(m.y) * 2)
            let agrees = shift.map { hypot(own.x - $0.x, own.y - $0.y) < 32 } ?? true
            let start = m.strength > minimumStrength && abs(m.x) < 64 && abs(m.y) < 64 && agrees ? own : shift
            return start.map { CGPoint(x: $0.x.rounded(), y: $0.y.rounded()) }
        }
        let tracked = centers.indices.filter { starts[$0] != nil }
        let moving = tiles(tracked.map { i in
            Tile(image: frame, gain: gain, scale: 1, center: CGPoint(x: centers[i].x + starts[i]!.x, y: centers[i].y + starts[i]!.y),
                 blur: fineBlur)
        }, side: fineSide, context: context)
        var matches: [(anchor: Int, match: Match)] = []
        for (k, i) in tracked.enumerated() {
            guard let (d, w) = refine(refFine[i], moving[k]) else { continue }
            // Back to Core Image's upward y.
            let information = simd_double2x2(rows: [SIMD2(w[0][0], -w[0][1]), SIMD2(-w[1][0], w[1][1])])
            let to = CGPoint(x: centers[i].x + starts[i]!.x + CGFloat(d.x), y: centers[i].y + starts[i]!.y - CGFloat(d.y))
            matches.append((i, Match(from: centers[i], to: to, information: information)))
        }

        // Something moving through a patch disagrees with the rest: drop the worst while it's far outside what
        // its own precision allows, keeping four for the fit.
        var used = matches
        var warp = fitAffine(used.map(\.match))
        while let fitted = warp, used.count > 4 {
            let misses = used.map { m -> Double in
                let p = m.match.from.applying(fitted)
                let r = SIMD2(Double(p.x - m.match.to.x), Double(p.y - m.match.to.y))
                return simd_length(r) < 0.3 ? 0 : simd_dot(r, m.match.information * r)
            }
            guard let worst = misses.indices.max(by: { misses[$0] < misses[$1] }), misses[worst] > 16 else { break }
            used.remove(at: worst)
            warp = fitAffine(used.map(\.match))
        }
        // A hand turns a fraction of a degree in a burst; anything far from that is a bad fit.
        if let fitted = warp, abs(fitted.a - 1) < 0.02, abs(fitted.d - 1) < 0.02, abs(fitted.b) < 0.02, abs(fitted.c) < 0.02 {
            return (fitted, used.count)
        }
        // Too few to fit a turn: the middle's shift, else the median of the others, else the frame's.
        let offsets = matches.map { CGPoint(x: $0.match.to.x - $0.match.from.x, y: $0.match.to.y - $0.match.from.y) }
        if let middle = matches.firstIndex(where: { $0.anchor == 0 }) {
            return (CGAffineTransform(translationX: offsets[middle].x, y: offsets[middle].y), 1)
        }
        if !offsets.isEmpty {
            let xs = offsets.map(\.x).sorted(), ys = offsets.map(\.y).sorted()
            return (CGAffineTransform(translationX: xs[xs.count / 2], y: ys[ys.count / 2]), offsets.count)
        }
        return shift.map { (CGAffineTransform(translationX: $0.x, y: $0.y), 0) }
    }

    /// Lucas–Kanade: the sub-pixel offset at which `moving` best matches `reference`, both fineSide square and
    /// row by row, compared over the middle 256. Returns the offset in patch pixels (y down) and its inverse
    /// covariance, or nil for a flat patch or one that doesn't settle.
    private static func refine(_ reference: [Float], _ moving: [Float]) -> (SIMD2<Double>, simd_double2x2)? {
        let side = fineSide, m = fineMargin, inner = fineSide - 2 * fineMargin
        let count = inner * inner
        var gx = [Float](repeating: 0, count: count), gy = [Float](repeating: 0, count: count), r = [Float](repeating: 0, count: count)
        var hxx = 0.0, hxy = 0.0, hyy = 0.0
        reference.withUnsafeBufferPointer { ref in
            for y in 0..<inner {
                for x in 0..<inner {
                    let i = (y + m) * side + x + m
                    let k = y * inner + x
                    gx[k] = 0.5 * (ref[i + 1] - ref[i - 1])
                    gy[k] = 0.5 * (ref[i + side] - ref[i - side])
                    r[k] = ref[i]
                    hxx += Double(gx[k] * gx[k]); hxy += Double(gx[k] * gy[k]); hyy += Double(gy[k] * gy[k])
                }
            }
        }
        let h = simd_double2x2(rows: [SIMD2(hxx, hxy), SIMD2(hxy, hyy)])
        guard h.determinant > 1e-12 * (hxx + hyy) * (hxx + hyy) else { return nil }
        let inverse = h.inverse
        var d = SIMD2<Double>.zero
        var variance = 0.0
        var settled = false
        moving.withUnsafeBufferPointer { mov in
            for _ in 0..<30 {
                let ox = Int(d.x.rounded(.down)), oy = Int(d.y.rounded(.down))
                let fx = Float(d.x) - Float(ox), fy = Float(d.y) - Float(oy)
                let (w00, w10, w01, w11) = ((1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy)
                var errors = [Float](repeating: 0, count: count)
                var mean = 0.0
                for y in 0..<inner {
                    for x in 0..<inner {
                        let i = (y + m + oy) * side + x + m + ox
                        let k = y * inner + x
                        let sample = w00 * mov[i] + w10 * mov[i + 1] + w01 * mov[i + side] + w11 * mov[i + side + 1]
                        errors[k] = sample - r[k]
                        mean += Double(errors[k])
                    }
                }
                // A brightness difference between frames isn't movement.
                mean /= Double(count)
                var b = SIMD2<Double>.zero
                variance = 0
                for k in 0..<count {
                    let e = Double(errors[k]) - mean
                    b += SIMD2(Double(gx[k]) * e, Double(gy[k]) * e)
                    variance += e * e
                }
                variance /= Double(count)
                let step = inverse * b
                d -= step
                guard abs(d.x) < Double(m - 1), abs(d.y) < Double(m - 1) else { return }
                if simd_length(step) < 0.003 {
                    settled = true
                    return
                }
            }
        }
        guard settled else { return nil }
        // Blurred noise is correlated over about 4π σ² pixels, so the patch has that many fewer independent samples.
        let information = h * (1 / (max(variance, 1e-10) * 4 * .pi * fineBlur * fineBlur))
        return (d, information)
    }

    /// Weighted least-squares affine through the matches, each counted by its own precision in each direction.
    /// Nil for fewer than four. A weak pull toward no turn keeps a fit that the patches leave loose in one
    /// direction from wandering.
    private static func fitAffine(_ matches: [Match]) -> CGAffineTransform? {
        guard matches.count >= 4 else { return nil }
        // Centered, so the normal equations stay well conditioned at 4000-pixel coordinates.
        let n = Double(matches.count)
        let cx = matches.map { Double($0.from.x) }.reduce(0, +) / n
        let cy = matches.map { Double($0.from.y) }.reduce(0, +) / n
        // Unknowns a, c, tx, b, d, ty: x' = a X + c Y + tx, y' = b X + d Y + ty.
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        var rhs = [Double](repeating: 0, count: 6)
        for m in matches {
            let X = Double(m.from.x) - cx, Y = Double(m.from.y) - cy
            let rows: [[Double]] = [[X, Y, 1, 0, 0, 0], [0, 0, 0, X, Y, 1]]
            let target = [Double(m.to.x), Double(m.to.y)]
            let w = m.information
            for i in 0..<6 {
                for j in 0..<6 {
                    for p in 0..<2 {
                        for q in 0..<2 {
                            normal[i][j] += rows[p][i] * w[q][p] * rows[q][j]
                        }
                    }
                }
                for p in 0..<2 {
                    for q in 0..<2 {
                        rhs[i] += rows[p][i] * w[q][p] * target[q]
                    }
                }
            }
        }
        // About a sixth of a degree of doubt on the turn, scale and skew.
        let prior = 1 / (0.003 * 0.003)
        for (i, identity) in [(0, 1.0), (1, 0.0), (3, 0.0), (4, 1.0)] {
            normal[i][i] += prior
            rhs[i] += prior * identity
        }
        guard let x = solve(normal, rhs) else { return nil }
        return CGAffineTransform(a: x[0], b: x[3], c: x[1], d: x[4],
                                 tx: x[2] - x[0] * cx - x[1] * cy, ty: x[5] - x[3] * cx - x[4] * cy)
    }

    /// Gaussian elimination with partial pivoting; nil when singular.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        let n = v.count
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            v.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let f = m[row][col] / m[col][col]
                for k in col..<n {
                    m[row][k] -= f * m[col][k]
                }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n {
                sum -= m[row][k] * x[k]
            }
            x[row] = sum / m[row][row]
        }
        return x
    }

    private static func middle(_ extent: CGRect) -> CGPoint {
        CGPoint(x: extent.midX.rounded(), y: extent.midY.rounded())
    }

    /// The anchor points in `extent`, on whole pixels so every patch lands on the pixel grid.
    private static func anchorCenters(_ extent: CGRect) -> [CGPoint] {
        anchors.map { CGPoint(x: (extent.minX + extent.width * $0.x).rounded(), y: (extent.minY + extent.height * $0.y).rounded()) }
    }

    private struct Tile {
        var image: CIImage
        var gain: Double
        var scale: CGFloat
        /// In the image's own pixels.
        var center: CGPoint
        var blur = 0.0
    }

    /// Square patches, exposure-matched, clamped and gamma-encoded, green channel row by row: side by side in
    /// one render, since each render waits on the GPU and on the A9 the wait costs more than the patches.
    private static func tiles(_ requests: [Tile], side: Int, context: CIContext) -> [[Float]] {
        guard !requests.isEmpty else { return [] }
        var strip = CIImage.empty()
        for (i, tile) in requests.enumerated() {
            var source = registrationImage(tile.image, gain: tile.gain, scale: tile.scale)
            if tile.blur > 0 {
                source = source.clampedToExtent().applyingGaussianBlur(sigma: tile.blur)
            }
            let origin = CGPoint(x: (tile.center.x * tile.scale).rounded() - CGFloat(side / 2),
                                 y: (tile.center.y * tile.scale).rounded() - CGFloat(side / 2))
            strip = source.cropped(to: CGRect(origin: origin, size: CGSize(width: side, height: side)))
                .transformed(by: CGAffineTransform(translationX: CGFloat(i * side) - origin.x, y: -origin.y))
                .composited(over: strip)
        }
        let width = side * requests.count
        var pixels = [SIMD4<Float>](repeating: .zero, count: width * side)
        pixels.withUnsafeMutableBytes {
            context.render(strip, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: side), format: .RGBAf, colorSpace: nil)
        }
        var out = [[Float]](repeating: [Float](repeating: 0, count: side * side), count: requests.count)
        for i in requests.indices {
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
