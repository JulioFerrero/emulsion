// RawLab: the app's own raw developer, run on the Mac against DNGs from the phone, next to Apple's.
// Build:
//   xcrun -sdk macosx metal -fcikernel Emulsion/Film/FilmKernels.metal -o build/default.metallib
//   xcrun --sdk macosx swiftc -O Tools/RawLab/main.swift Emulsion/Darkroom/DNG.swift Emulsion/Darkroom/RawDeveloper.swift -o build/rawlab
// Usage: build/rawlab <out-dir> <negative.dng>...

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func pixels(_ image: CIImage, _ rect: CGRect) -> [SIMD4<Float>] {
    var p = [SIMD4<Float>](repeating: .zero, count: Int(rect.width * rect.height))
    p.withUnsafeMutableBytes {
        context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(rect.width) * 16, bounds: rect, format: .RGBAf, colorSpace: linear)
    }
    return p
}

func save(_ image: CIImage, _ rect: CGRect, gain: Double, _ path: String) {
    let shown = image.cropped(to: rect).applyingFilter("CIExposureAdjust", parameters: ["inputEV": log2(gain)])
    let cg = context.createCGImage(shown, from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
}

func apple(_ url: URL) -> CIImage? {
    guard let f = CIRAWFilter(imageURL: url) else { return nil }
    f.boostAmount = 0
    if f.isLocalToneMapSupported { f.localToneMapAmount = 0 }
    if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0 }
    if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0 }
    if f.isSharpnessSupported { f.sharpnessAmount = 0 }
    return f.outputImage
}

let calibrate = ProcessInfo.processInfo.environment["CALIBRATE"] != nil
/// Pairs of (ours, apple) mid-tone pixels from every frame, to fit the color matrix between them.
var pairs: [(SIMD3<Double>, SIMD3<Double>)] = []
for path in CommandLine.arguments.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    guard let data = try? Data(contentsOf: url), let dng = DNG(data: data), let bayer = dng.decodeBayer(),
          let theirs = apple(url) else { continue }
    let start = Date()
    guard let ours = RawDeveloper.develop(RawDeveloper.bayerImage(bayer, width: dng.width, height: dng.height), dng: dng) else { continue }
    let e = ours.extent
    // Force the render now, to time the GPU work.
    _ = pixels(ours, CGRect(x: e.midX, y: e.midY, width: 1, height: 1))
    let developTime = Date().timeIntervalSince(start)

    // Compare on a grid of 256×256 samples, mid-tones only.
    let small = CGRect(x: 0, y: 0, width: 256, height: 256)
    func grid(_ i: CIImage) -> [SIMD4<Float>] {
        let s = i.transformed(by: CGAffineTransform(scaleX: 256 / i.extent.width, y: 256 / i.extent.height))
        return pixels(s, small)
    }
    let a = grid(ours), b = grid(theirs)
    var ratios: [[Float]] = [[], [], []]
    for i in a.indices where (b[i].y > 0.03 && b[i].y < 0.5 && a[i].y > 0.01) {
        for c in 0..<3 where b[i][c] > 0.01 && a[i][c] > 0.005 { ratios[c].append(a[i][c] / b[i][c]) }
    }
    for i in a.indices where b[i].y > 0.02 && b[i].y < 0.5 && max(b[i].x, b[i].z) < 0.8 {
        pairs.append((SIMD3(Double(a[i].x), Double(a[i].y), Double(a[i].z)), SIMD3(Double(b[i].x), Double(b[i].y), Double(b[i].z))))
    }
    let medians = ratios.map { $0.isEmpty ? 0 : $0.sorted()[$0.count / 2] }
    print(name, String(format: "developed in %.2fs  ours/apple  R %.3f  G %.3f  B %.3f  (%d samples)",
                       developTime, medians[0], medians[1], medians[2], ratios[1].count))
    // Ratio by tone: a constant means plain exposure, rising toward black means Apple subtracts an offset.
    let edges: [Float] = [0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5]
    var line = "   by tone (apple G):"
    for (lo, hi) in zip(edges, edges.dropFirst()) {
        let r = a.indices.filter { b[$0].y >= lo && b[$0].y < hi }.map { a[$0].y / b[$0].y }.sorted()
        line += r.count < 20 ? "  -" : String(format: "  %.3f→%.2f", lo, r[r.count / 2])
    }
    print(line)
    // The offset in sensor units, after matching mid-tone exposure.
    let mid = a.indices.filter { b[$0].y > 0.1 && b[$0].y < 0.5 }.map { a[$0].y / b[$0].y }.sorted()
    let scale = mid.isEmpty ? 1 : mid[mid.count / 2]
    let offsets = a.indices.filter { b[$0].y > 0.003 && b[$0].y < 0.04 }.map { a[$0].y - b[$0].y * scale }.sorted()
    if !offsets.isEmpty {
        let offset = Double(offsets[offsets.count / 2])
        let units = offset / exp2(dng.baselineExposure) * (dng.whiteLevel - dng.blackLevel)
        let darkest = bayer.enumerated().filter { ($0.offset / dng.width) % 2 == 0 && $0.offset % 2 == 1 }.map(\.element).sorted()
        print(String(format: "   offset %.4f linear = %.1f sensor units (baseline %.2f, ISO noise S %.2e)  green p0.1 %d  p1 %d",
                     offset, units, dng.baselineExposure, dng.noiseProfile.x,
                     darkest[darkest.count / 1000], darkest[darkest.count / 100]))
    }
    if calibrate { continue }

    // Full frame side by side, and 1:1 crops from the middle.
    let g = 0.18 / Double(max(b.map(\.y).sorted()[b.count / 2], 0.01))
    let scaled = { (i: CIImage) in i.transformed(by: CGAffineTransform(scaleX: 900 / i.extent.width, y: 900 / i.extent.width)) }
    save(scaled(ours), scaled(ours).extent.integral, gain: g, "\(out)/\(name)-ours.png")
    save(scaled(theirs), scaled(theirs).extent.integral, gain: g, "\(out)/\(name)-apple.png")
    let crop = CGRect(x: e.midX - 300, y: e.midY - 300, width: 600, height: 600).integral
    save(ours, crop, gain: g, "\(out)/\(name)-ours-crop.png")
    save(theirs, crop, gain: g, "\(out)/\(name)-apple-crop.png")
}

// Least squares: apple ≈ M · ours, rows then scaled so a neutral stays neutral.
if pairs.count > 100 {
    var ata = simd_double3x3(0), atb = [simd_double3x3(0)]
    _ = atb
    var sums = [SIMD3<Double>](repeating: .zero, count: 3)
    for (o, a) in pairs {
        ata += simd_double3x3(columns: (o * o.x, o * o.y, o * o.z))
        for c in 0..<3 { sums[c] += o * a[c] }
    }
    let inverse = ata.inverse
    var rows = (0..<3).map { inverse * sums[$0] }
    rows = rows.map { $0 / ($0.x + $0.y + $0.z) }
    print("look matrix from \(pairs.count) pixels:")
    for r in rows { print(String(format: "  SIMD3(%.4f, %.4f, %.4f),", r.x, r.y, r.z)) }
}
