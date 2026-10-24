import CoreImage
import CoreVideo
import simd

/// A capture's Bayer mosaic, copied out of the camera's buffer so the buffer goes straight back to the camera.
struct BayerFrame {
    var data: Data
    var width: Int
    var height: Int
    var rowBytes: Int

    init?(copying buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        data = Data(bytes: base, count: rowBytes * height)
    }

    /// A textured stand-in at `scale` sensor units, for warming up.
    init(standInWidth width: Int, height: Int, scale: Int) {
        self.width = width
        self.height = height
        rowBytes = width * 2
        var values = [UInt16](repeating: 0, count: width * height)
        var seed: UInt32 = 12345
        for i in values.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            values[i] = UInt16((600 + Int(seed >> 22)) * scale)
        }
        data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    var image: CIImage {
        CIImage(bitmapData: data, bytesPerRow: rowBytes, size: CGSize(width: width, height: height),
                format: .L16, colorSpace: nil)
    }

    func value(x: Int, y: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: y * rowBytes + x * 2, as: UInt16.self) }
    }
}

/// Develops Bayer data on the GPU without Apple's RAW pipeline: no noise smearing, no sharpening, no tone curve.
/// Demosaic, the DNG's own color calibration and lens vignetting correction, chroma-only noise reduction.
/// Output is scene-linear sRGB, upright, at the same brightness Core Image's RAW filter gives.
enum RawDeveloper {
    /// Apple's RAW filter lands this much brighter than (raw − black) / range × 2^baseline.
    static var exposureCalibration = 1.0
    /// Sensor units taken off above the DNG's black level: lens flare and pedestal, measured against Apple's
    /// own development of the same frames (12–21 units at ISO 25–400). Without it blacks print milky.
    /// Less at high ISO, where Apple takes less off too.
    static func flare(_ dng: DNG) -> Double {
        let noisy = min(max((dng.noiseProfile.x - 4e-5) / 1.6e-4, 0), 1)
        return 15 - 6 * noisy
    }

    /// `levelScale` converts the DNG's sensor levels to the mosaic's units (1 when they're the same data).
    /// `chroma` is the blur radius for color noise at a 4032 px frame; 0 turns it off.
    static func develop(_ bayer: CIImage, dng: DNG, levelScale: Double = 1, chroma: Double = 2.5) -> CIImage? {
        let extent = bayer.extent
        let height = Float(extent.height)
        let gains = 1 / dng.asShotNeutral
        guard let prepared = RawKernels.bayerPrep.apply(extent: extent, arguments: [
            bayer, Float(dng.blackLevel * levelScale), Float((dng.whiteLevel - dng.blackLevel) * levelScale),
            CIVector(x: gains.x, y: gains.y, z: gains.z), Float(flare(dng) / (dng.whiteLevel - dng.blackLevel)), height,
        ]),
            let camera = RawKernels.demosaic.apply(
                extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
                arguments: [prepared.clampedToExtent(), height])
        else { return nil }

        let m = cameraToSRGB(dng)
        let k = dng.vignette + Array(repeating: 0, count: max(0, 5 - dng.vignette.count))
        // DNG measures the optical center from the top; Core Image from the bottom.
        let center = CIVector(x: dng.vignetteCenter.x, y: 1 - dng.vignetteCenter.y)
        guard var linear = RawKernels.rawColor.apply(extent: extent, arguments: [
            camera,
            CIVector(x: m[0][0], y: m[1][0], z: m[2][0]),
            CIVector(x: m[0][1], y: m[1][1], z: m[2][1]),
            CIVector(x: m[0][2], y: m[1][2], z: m[2][2]),
            Float(exp2(dng.baselineExposure) * exposureCalibration),
            CIVector(x: k[0], y: k[1], z: k[2], w: k[3]), Float(k[4]),
            center, CIVector(x: extent.width, y: extent.height),
        ]) else { return nil }

        if chroma > 0 {
            linear = reduceChroma(linear, radius: chroma)
        }
        let orientation = CGImagePropertyOrientation(rawValue: UInt32(dng.orientation)) ?? .up
        return linear.oriented(orientation)
    }

    /// Unsharp mask in square-root space; `radius` in output pixels.
    static func sharpen(_ image: CIImage, radius: Double, amount: Double) -> CIImage {
        let extent = image.extent
        guard let root = RawKernels.rootRGB.apply(extent: extent, arguments: [image]) else { return image }
        let blurred = root.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        return FilmKernels.sharpenRoot.apply(extent: extent, arguments: [image, blurred, Float(amount)]) ?? image
    }

    /// Lightness from `image`, color from a blurred copy, in square-root space where noise is even.
    /// `radius` is for a 4032 px frame.
    static func reduceChroma(_ image: CIImage, radius: Double) -> CIImage {
        let extent = image.extent
        let sigma = radius * Double(max(extent.width, extent.height)) / 4032
        guard let root = RawKernels.rootRGB.apply(extent: extent, arguments: [image]) else { return image }
        let blurred = root.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        return RawKernels.chromaMerge.apply(extent: extent, arguments: [image, blurred]) ?? image
    }

    /// The mosaic as a one-channel image, top row first.
    static func bayerImage(_ pixels: [UInt16], width: Int, height: Int) -> CIImage {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 2, size: CGSize(width: width, height: height),
                       format: .L16, colorSpace: nil)
    }

    private static var checkedScale: Double?

    /// The capture's buffer should hold exactly the values its DNG stores. Checked once, on one tile:
    /// returns the factor from DNG units to buffer units, or nil if they don't describe the same data.
    static func levelScale(_ bayer: BayerFrame, matching dng: DNG) -> Double? {
        if let checkedScale {
            return checkedScale
        }
        guard bayer.width == dng.width, bayer.height == dng.height, let tile = dng.decodeTile(0) else { return nil }
        var same = 0, count = 0
        var sumBuffer = 0.0, sumFile = 0.0
        for row in stride(from: 0, to: tile.height, by: 3) {
            for col in stride(from: 0, to: tile.width, by: 3) {
                let b = Double(bayer.value(x: tile.x + col, y: tile.y + row))
                let d = Double(tile.samples[row * tile.width + col])
                same += b == d ? 1 : 0
                count += 1
                sumBuffer += b
                sumFile += d
            }
        }
        let scale: Double
        if same * 100 >= count * 99 {
            scale = 1
        } else {
            // Same picture at another bit depth, or not the same picture at all.
            let ratio = sumBuffer / max(sumFile, 1)
            let rounded = exp2(log2(ratio).rounded())
            guard abs(ratio / rounded - 1) < 0.02 else { return nil }
            scale = rounded
        }
        checkedScale = scale
        return scale
    }

    /// White-balanced camera RGB to linear sRGB, from the DNG's two calibrations, interpolated for the
    /// light at capture the way the DNG spec does it, then adapted from that light's white to D65.
    static func cameraToSRGB(_ dng: DNG) -> simd_double3x3 {
        let neutral = dng.asShotNeutral
        var xyzToCamera = dng.colorMatrixD65
        for _ in 0..<5 {
            let white = xyzToCamera.inverse * neutral
            let sum = white.x + white.y + white.z
            let temperature = correlatedColorTemperature(x: white.x / sum, y: white.y / sum)
            // Linear in mireds between illuminant A (2856 K) and D65 (6504 K).
            let t = min(max((1 / temperature - 1 / 2856) / (1 / 6504 - 1 / 2856), 0), 1)
            xyzToCamera = dng.colorMatrixA * (1 - t) + dng.colorMatrixD65 * t
        }
        var white = xyzToCamera.inverse * neutral
        white /= white.y
        let full = xyzToSRGB * bradford(from: white, to: d65) * xyzToCamera.inverse
        var m = full * simd_double3x3(diagonal: neutral)
        // Exactly neutral for a neutral: white-balanced (1, 1, 1) prints as (1, 1, 1).
        let unit = m * SIMD3(1, 1, 1)
        m = simd_double3x3(diagonal: 1 / unit) * m
        return look * m
    }

    /// Apple's rendering of this sensor is a touch richer in red than the DNG's calibration; the film stocks
    /// were tuned on Apple's color. Fitted by least squares over 1.8 million pixels from 47 frames; each row
    /// sums to 1, so neutrals stay neutral.
    private static let look = simd_double3x3(rows: [
        SIMD3(1.0845, 0.0018, -0.0863),
        SIMD3(-0.0112, 1.0351, -0.0239),
        SIMD3(-0.0303, 0.0685, 0.9618),
    ])

    private static let d65 = SIMD3(0.95047, 1.0, 1.08883)

    private static let xyzToSRGB = simd_double3x3(rows: [
        SIMD3(3.2404542, -1.5371385, -0.4985314),
        SIMD3(-0.9692660, 1.8760108, 0.0415560),
        SIMD3(0.0556434, -0.2040259, 1.0572252),
    ])

    private static func bradford(from source: SIMD3<Double>, to target: SIMD3<Double>) -> simd_double3x3 {
        let b = simd_double3x3(rows: [
            SIMD3(0.8951, 0.2664, -0.1614),
            SIMD3(-0.7502, 1.7135, 0.0367),
            SIMD3(0.0389, -0.0685, 1.0296),
        ])
        let scale = (b * target) / (b * source)
        return b.inverse * simd_double3x3(diagonal: scale) * b
    }

    /// McCamy's approximation.
    private static func correlatedColorTemperature(x: Double, y: Double) -> Double {
        let n = (x - 0.3320) / (0.1858 - y)
        return min(max(449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33, 2000), 12000)
    }
}

enum RawKernels {
    static let bayerPrep = color("bayerPrep")
    static let rawColor = color("rawColor")
    static let rootRGB = color("rootRGB")
    static let chromaMerge = color("chromaMerge")
    static let demosaic: CIKernel = {
        guard let kernel = try? CIKernel(functionName: "demosaic", fromMetalLibraryData: library) else {
            fatalError("Could not load kernel demosaic")
        }
        return kernel
    }()

    /// The app's bundle, or next to the executable for the Mac tools.
    private static let library: Data = {
        let candidates = [
            Bundle.main.url(forResource: "default", withExtension: "metallib"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("default.metallib"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        fatalError("Core Image kernels are missing")
    }()

    private static func color(_ name: String) -> CIColorKernel {
        guard let kernel = try? CIColorKernel(functionName: name, fromMetalLibraryData: library) else {
            fatalError("Could not load kernel \(name)")
        }
        return kernel
    }
}
