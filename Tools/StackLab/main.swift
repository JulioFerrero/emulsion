// StackLab: runs the app's own Stacker and Core Image kernels on the Mac against DNGs from the phone.
// Build:
//   xcrun -sdk macosx metal -fcikernel Emulsion/Film/FilmKernels.metal -o build/default.metallib
//   xcrun --sdk macosx swiftc -O Tools/StackLab/main.swift Emulsion/Darkroom/Stacker.swift Emulsion/Darkroom/Timing.swift Emulsion/Darkroom/PhaseCorrelator.swift -o build/stacklab
// Usage: build/stacklab <out-dir> <frame.dng>...   (the middle exposure is the reference)

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FilmKernels {
    static let accumulateFrame = load("accumulateFrame")
    static let resolveMerge = load("resolveMerge")

    private static let library: Data = {
        let url = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("default.metallib")
        return try! Data(contentsOf: url)
    }()

    private static func load(_ name: String) -> CIColorKernel {
        try! CIColorKernel(functionName: name, fromMetalLibraryData: library)
    }
}

let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])

func develop(_ url: URL, noiseReduction: Float, baseline: Float?) -> CIImage {
    let filter = CIRAWFilter(imageURL: url)!
    if let baseline { filter.baselineExposure = baseline }
    filter.boostAmount = 0
    if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
    if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = noiseReduction }
    if filter.isSharpnessSupported { filter.sharpnessAmount = 0.2 }
    return filter.outputImage!
}

func exposure(_ url: URL) -> Double {
    let props = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [String: Any]
    let exif = props[kCGImagePropertyExifDictionary as String] as! [String: Any]
    return (exif["ExposureTime"] as! Double) * Double((exif["ISOSpeedRatings"] as! [Int])[0])
}

/// A 1:1 crop from the middle, brightened so the median sits at mid-gray, sRGB PNG.
func save(_ image: CIImage, gain: CGFloat, _ path: String) {
    let e = image.extent
    let crop = CGRect(x: e.midX - 400, y: e.midY - 300, width: 800, height: 600)
    let bright = image.cropped(to: crop).applyingFilter("CIExposureAdjust", parameters: ["inputEV": log2(gain)])
    write(bright, crop, path)
    // And a 3× detail from the same spot, to judge noise.
    let detail = CGRect(x: crop.midX - 60, y: crop.minY + 120, width: 260, height: 200)
    let zoomed = bright.cropped(to: detail).samplingNearest().transformed(by: CGAffineTransform(scaleX: 3, y: 3))
    write(zoomed, zoomed.extent, path.replacingOccurrences(of: ".png", with: "-3x.png"))
}

func write(_ image: CIImage, _ rect: CGRect, _ path: String) {
    let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

/// Noise: spread of green around its local mean, over a flat patch of curtain, relative to its level.
func noise(_ image: CIImage) -> Double {
    let e = image.extent
    let patch = CGRect(x: e.midX - 220, y: e.midY + 20, width: 190, height: 260)
    let local = image.clampedToExtent().applyingGaussianBlur(sigma: 2)
    func pixels(_ i: CIImage) -> [Float] {
        var px = [Float](repeating: 0, count: Int(patch.width * patch.height) * 4)
        px.withUnsafeMutableBytes { context.render(i, toBitmap: $0.baseAddress!, rowBytes: Int(patch.width) * 16, bounds: patch, format: .RGBAf, colorSpace: nil) }
        return stride(from: 1, to: px.count, by: 4).map { px[$0] }
    }
    let level = pixels(local), d = pixels(image).enumerated().map { $0.element - level[$0.offset] }
    let mean = Double(level.reduce(0, +)) / Double(level.count)
    let rms = sqrt(Double(d.map { $0 * $0 }.reduce(0, +)) / Double(d.count))
    return rms / mean
}

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let urls = CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let exposures = urls.map(exposure)
let reference = urls.indices.sorted { exposures[$0] < exposures[$1] }[urls.count / 2]
let baseline = CIRAWFilter(imageURL: urls[reference])!.baselineExposure

let start = Date()
let frames = urls.indices.map { Stacker.Frame(image: develop(urls[$0], noiseReduction: 0.15, baseline: baseline), exposure: exposures[$0]) }
let merged = Stacker.merge(frames, reference: reference, context: context, progress: { _ in })!
save(merged, gain: 3, "\(out)/merged.png")
print(String(format: "merged %d frames in %.1fs", urls.count, Date().timeIntervalSince(start)))
let single = develop(urls[reference], noiseReduction: 0.45, baseline: nil)
save(single, gain: 3, "\(out)/single.png")
let raw = develop(urls[reference], noiseReduction: 0.15, baseline: nil)
print(String(format: "noise  single NR0.15 %.4f   single NR0.45 %.4f   merged %.4f", noise(raw), noise(single), noise(merged)))
