// FilmLab: renders the app's film model on the Mac for tuning.
// Build: xcrun --sdk macosx swiftc -O Emulsion/Film/FilmStock.swift Emulsion/Film/FilmModel.swift Tools/FilmLab/main.swift -o build/filmlab
// Usage: build/filmlab <out-dir> [photo...]

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

// MARK: - Grain (port of the Metal kernel)

func fract(_ x: Float) -> Float { x - x.rounded(.down) }

func log2v(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(log2(v.x), log2(v.y), log2(v.z)) }

func hash12(_ p: SIMD2<Float>) -> Float {
    var p3 = SIMD3(fract(p.x * 0.1031), fract(p.y * 0.1031), fract(p.x * 0.1031))
    p3 += dot(p3, SIMD3(p3.y, p3.z, p3.x) + 33.33)
    return fract((p3.x + p3.y) * p3.z)
}

func valueNoise(_ p: SIMD2<Float>) -> Float {
    let i = SIMD2(p.x.rounded(.down), p.y.rounded(.down))
    let f = p - i
    let u = f * f * (3 - 2 * f)
    let a = hash12(i), b = hash12(i + SIMD2(1, 0)), c = hash12(i + SIMD2(0, 1)), d = hash12(i + SIMD2(1, 1))
    let top = a + (b - a) * u.x
    let bottom = c + (d - c) * u.x
    return top + (bottom - top) * u.y
}

func grainNoise(_ p: SIMD2<Float>) -> Float {
    valueNoise(p) * 0.7 + valueNoise(p * 2.03 + 17.17) * 0.3 - 0.5
}

// MARK: - Image IO (linear sRGB float buffers)

struct Picture {
    var width: Int
    var height: Int
    var pixels: [SIMD3<Float>]
}

/// DNGs develop the way the app develops them: scene-linear, no tone curve, no local tone mapping.
func loadRAW(_ path: String, maxSide: Int) -> Picture? {
    guard let filter = CIRAWFilter(imageURL: URL(fileURLWithPath: path)) else { return nil }
    filter.boostAmount = 0
    if filter.isLocalToneMapSupported { filter.localToneMapAmount = 0 }
    guard let raw = filter.outputImage else { return nil }
    let scale = Double(maxSide) / Double(max(raw.extent.width, raw.extent.height))
    let image = raw.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
    let e = image.extent.integral
    let w = Int(e.width), h = Int(e.height)
    var floats = [Float](repeating: 0, count: w * h * 4)
    floats.withUnsafeMutableBytes {
        CIContext().render(image, toBitmap: $0.baseAddress!, rowBytes: w * 16, bounds: e, format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB))
    }
    var pixels = [SIMD3<Float>](repeating: .zero, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            // Core Image's first row is the bottom one.
            let i = ((h - 1 - y) * w + x) * 4
            pixels[y * w + x] = simd_max(SIMD3(floats[i], floats[i + 1], floats[i + 2]), .zero)
        }
    }
    return Picture(width: w, height: h, pixels: pixels)
}

func load(_ path: String, maxSide: Int) -> Picture? {
    if path.lowercased().hasSuffix(".dng") {
        return loadRAW(path, maxSide: maxSide)
    }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let lut = (0..<256).map { Float(srgbToLinear(Double($0) / 255)) }
    var pixels = [SIMD3<Float>](repeating: .zero, count: w * h)
    for i in 0..<(w * h) {
        pixels[i] = SIMD3(lut[Int(bytes[i * 4])], lut[Int(bytes[i * 4 + 1])], lut[Int(bytes[i * 4 + 2])])
    }
    return Picture(width: w, height: h, pixels: pixels)
}

func encode(_ v: Float) -> UInt8 {
    let c = min(max(Double(v), 0), 1)
    let e = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    return UInt8((e * 255).rounded())
}

func save(_ picture: Picture, _ path: String) {
    var bytes = [UInt8](repeating: 255, count: picture.width * picture.height * 4)
    for (i, p) in picture.pixels.enumerated() {
        bytes[i * 4] = encode(p.x)
        bytes[i * 4 + 1] = encode(p.y)
        bytes[i * 4 + 2] = encode(p.z)
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &bytes, width: picture.width, height: picture.height, bitsPerComponent: 8,
                        bytesPerRow: picture.width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Development (CPU twin of FilmRenderer)

struct Cube {
    let n: Int
    let data: [Float]

    init(_ stock: FilmStock) {
        n = FilmLUT.dimension
        data = FilmLUT.make(for: stock)
    }

    func sample(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let s = simd_clamp(v, .zero, .one) * Float(n - 1)
        let i0 = SIMD3<Int>(Int(s.x), Int(s.y), Int(s.z))
        let i1 = SIMD3<Int>(min(i0.x + 1, n - 1), min(i0.y + 1, n - 1), min(i0.z + 1, n - 1))
        let f = s - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            let k = ((b * n + g) * n + r) * 4
            return SIMD3(data[k], data[k + 1], data[k + 2])
        }
        let c00 = simd_mix(at(i0.x, i0.y, i0.z), at(i1.x, i0.y, i0.z), SIMD3(repeating: f.x))
        let c10 = simd_mix(at(i0.x, i1.y, i0.z), at(i1.x, i1.y, i0.z), SIMD3(repeating: f.x))
        let c01 = simd_mix(at(i0.x, i0.y, i1.z), at(i1.x, i0.y, i1.z), SIMD3(repeating: f.x))
        let c11 = simd_mix(at(i0.x, i1.y, i1.z), at(i1.x, i1.y, i1.z), SIMD3(repeating: f.x))
        let c0 = simd_mix(c00, c10, SIMD3(repeating: f.y))
        let c1 = simd_mix(c01, c11, SIMD3(repeating: f.y))
        return simd_mix(c0, c1, SIMD3(repeating: f.z))
    }
}

let grainRMS: Float = 0.163

func develop(_ picture: Picture, _ stock: FilmStock, push: Int = 0, longEdge: Int = 4032, grain: Bool = true) -> Picture {
    let film = stock.developed(push: push)
    let cube = Cube(film)
    let size = Float(film.grainSize) * Float(max(picture.width, picture.height)) / Float(longEdge)
    let amount = Float(film.grain) / (Float(Shaper.range) * grainRMS) * min(size, 1)
    let chroma = Float(film.grainColor)
    var out = picture
    for y in 0..<picture.height {
        for x in 0..<picture.width {
            let i = y * picture.width + x
            let stops = log2v(simd_max(picture.pixels[i], SIMD3(repeating: 1e-6)) / 0.18)
            var v = simd_clamp((stops + Float(Shaper.floor)) / Float(Shaper.range), .zero, .one)
            if grain {
                let p = (SIMD2(Float(x), Float(y)) + 37) / max(size, 1)
                let luma = grainNoise(p)
                let dye = SIMD3(grainNoise(p + 101.3), luma, grainNoise(p + 211.7))
                let g = simd_mix(SIMD3(repeating: luma), dye, SIMD3(repeating: chroma))
                v = simd_clamp(v + g * amount, .zero, .one)
            }
            out.pixels[i] = cube.sample(v)
        }
    }
    return out
}

// MARK: - Charts

let checker: [(Double, Double, Double)] = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
    (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
    (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]

/// One row per stock: a ramp from -8 to +6 stops, then the 24 ColorChecker patches.
func chart() -> Picture {
    let patch = 36, rampWidth = 14 * patch
    let rows = FilmStock.all.count + 1
    let width = rampWidth + 24 * patch
    var picture = Picture(width: width, height: rows * patch, pixels: .init(repeating: .zero, count: width * rows * patch))
    for row in 0..<rows {
        let stock = row == 0 ? nil : FilmStock.all[row - 1]
        let cube = stock.map(Cube.init)
        for y in 0..<patch {
            for x in 0..<width {
                var scene: SIMD3<Double>
                if x < rampWidth {
                    let stops = -8 + 14 * Double(x) / Double(rampWidth)
                    scene = SIMD3(repeating: 0.18 * exp2(stops))
                } else {
                    let c = checker[(x - rampWidth) / patch]
                    scene = SIMD3(srgbToLinear(c.0 / 255), srgbToLinear(c.1 / 255), srgbToLinear(c.2 / 255))
                }
                var display = SIMD3<Float>(Float(scene.x), Float(scene.y), Float(scene.z))
                if let cube {
                    let stops = log2v(simd_max(display, SIMD3(repeating: 1e-6)) / 0.18)
                    display = cube.sample((stops + Float(Shaper.floor)) / Float(Shaper.range))
                }
                picture.pixels[(row * patch + y) * width + x] = display
            }
        }
    }
    return picture
}

func contactSheet(_ pictures: [Picture], columns: Int) -> Picture {
    let w = pictures[0].width, h = pictures[0].height, gap = 8
    let rows = (pictures.count + columns - 1) / columns
    let width = columns * w + (columns - 1) * gap
    let height = rows * h + (rows - 1) * gap
    var sheet = Picture(width: width, height: height, pixels: .init(repeating: .zero, count: width * height))
    for (n, p) in pictures.enumerated() {
        let ox = (n % columns) * (w + gap), oy = (n / columns) * (h + gap)
        for y in 0..<min(h, p.height) {
            for x in 0..<min(w, p.width) {
                sheet.pixels[(oy + y) * width + ox + x] = p.pixels[y * p.width + x]
            }
        }
    }
    return sheet
}

// MARK: - Main

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var samples: [Float] = []
for i in 0..<20000 {
    samples.append(grainNoise(SIMD2(Float(i % 200) * 0.37, Float(i / 200) * 0.41)))
}
let mean = samples.reduce(0, +) / Float(samples.count)
let rms = (samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(samples.count)).squareRoot()
print(String(format: "grain noise RMS %.4f (renderer assumes %.4f)\n", rms, grainRMS))

print("stock            -6     -4     -2      0     +1   +2.3   +3.3   +4.5  stops")
for stock in FilmStock.all {
    let curve = ToneCurve(stock: stock)
    let levels = [-6, -4, -2, 0, 1, 2.3, 3.3, 4.5].map { stops -> String in
        let out = curve.map(0.18 * exp2(stops), channel: 1)
        return String(format: "%6.3f", Double(encode(Float(out))) / 255)
    }
    print(stock.label.padding(toLength: 15, withPad: " ", startingAt: 0), levels.joined(separator: " "))
}

save(chart(), "\(outDir)/chart.png")

for path in args.dropFirst(2) where ProcessInfo.processInfo.environment["FILTERS"] != nil {
    // Black and white through each contrast filter.
    guard let picture = load(path, maxSide: 520) else { continue }
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let stocks = [FilmStock.monoPush] + BWFilter.allCases.map { FilmStock.monoPush.through($0) }
    save(contactSheet([picture] + stocks.map { develop(picture, $0) }, columns: 3), "\(outDir)/\(name)-filters.png")
}

for path in args.dropFirst(2) where ProcessInfo.processInfo.environment["FILTERS"] == nil {
    guard let picture = load(path, maxSide: 520) else { continue }
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    let developed = [picture] + FilmStock.all.map { develop(picture, $0) }
    save(contactSheet(developed, columns: 4), "\(outDir)/\(name)-sheet.png")

    // Full-resolution crop to judge grain the way it prints.
    if ProcessInfo.processInfo.environment["GRAIN"] != nil, let full = load(path, maxSide: 4032) {
        let side = 700
        var crop = Picture(width: side, height: side, pixels: [])
        let ox = (full.width - side) / 2, oy = (full.height - side) / 2
        for y in 0..<side { for x in 0..<side { crop.pixels.append(full.pixels[(oy + y) * full.width + ox + x]) } }
        let longEdge = side * 4032 / max(full.width, full.height)
        let crops = [FilmStock.negative, .tungsten, .monoPush, .acros].map { develop(crop, $0, longEdge: longEdge) }
        save(contactSheet(crops, columns: 2), "\(outDir)/\(name)-grain.png")
    }
}
print("wrote \(outDir)")
