import Foundation
import simd

/// The encoding the film LUT is indexed in: scene exposure in stops around 18% gray, from -10 to +6.
enum Shaper {
    static let floor = 10.0
    static let range = 16.0

    static func decode(_ v: Double) -> Double {
        0.18 * exp2(v * range - floor)
    }
}

enum FilmLUT {
    static let dimension = 32

    /// The film model baked into RGBA float cube data, indexed in shaper encoding.
    static func make(for stock: FilmStock) -> [Float] {
        let n = dimension
        let curve = ToneCurve(stock: stock)
        let axis = (0..<n).map { Shaper.decode(Double($0) / Double(n - 1)) }
        var values = [Float](repeating: 1, count: n * n * n * 4)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = FilmModel.render(SIMD3(axis[r], axis[g], axis[b]), stock: stock, curve: curve)
                    values[i] = Float(out.x)
                    values[i + 1] = Float(out.y)
                    values[i + 2] = Float(out.z)
                    i += 4
                }
            }
        }
        return values
    }
}

/// Scene-linear light in, display-linear light out.
enum FilmModel {
    static func render(_ scene: SIMD3<Double>, stock: FilmStock, curve: ToneCurve) -> SIMD3<Double> {
        var rgb = scene
        if let sensitivity = stock.monochrome {
            rgb = SIMD3(repeating: max(dot(rgb, sensitivity), 0))
        }
        var out = SIMD3(
            curve.map(rgb.x, channel: 0),
            curve.map(rgb.y, channel: 1),
            curve.map(rgb.z, channel: 2))
        if stock.monochrome == nil {
            out = grade(out, stock: stock)
        }
        return out.clamped(lowerBound: .zero, upperBound: .one)
    }

    private static func grade(_ rgb: SIMD3<Double>, stock s: FilmStock) -> SIMD3<Double> {
        let lab = OKLab.fromLinearSRGB(rgb)
        var lightness = lab.x
        var chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        var hue = atan2(lab.z, lab.y) * 180 / .pi

        chroma *= s.saturation
        chroma *= 1 - s.highlightDesaturation * smoothStep(0.65, 1, lightness)
        chroma *= 1 - s.shadowDesaturation * (1 - smoothStep(0, 0.3, lightness))

        // Sensor blues decode toward violet when dark and saturated; film dyes never go there.
        // Pull them back toward cyan, more the deeper they are.
        let violet = abs(remainder(hue - 285, 360))
        if violet < 35 {
            let weight = 0.5 * (1 + cos(.pi * violet / 35)) * (1 - smoothStep(0.3, 0.7, lightness))
            hue -= 14 * weight
            chroma *= 1 - 0.15 * weight
        }

        // Lightness moves only make sense on colors, not on neutrals.
        let colorfulness = min(chroma / 0.06, 1)
        for band in s.hueBands {
            let distance = abs(remainder(hue - band.center, 360))
            guard distance < band.width else { continue }
            let weight = 0.5 * (1 + cos(.pi * distance / band.width))
            hue += weight * band.hueShift
            chroma *= 1 + weight * (band.chroma - 1)
            lightness += weight * band.lightness * colorfulness
        }

        // Dyes can't reach the screen's most saturated colors; ease toward their limit instead of clipping.
        let knee = 0.6 * s.gamut
        if chroma > knee {
            chroma = knee + (s.gamut - knee) * tanh((chroma - knee) / (s.gamut - knee))
        }

        // Fade the shadow tint out toward black so blacks stay neutral.
        let shadows = smoothStep(0, 0.15, lightness) * (1 - smoothStep(0.15, 0.5, lightness))
        let highlights = smoothStep(0.55, 1, lightness)
        let radians = hue * .pi / 180
        let a = chroma * cos(radians) + s.shadowTint.x * shadows + s.highlightTint.x * highlights
        let b = chroma * sin(radians) + s.shadowTint.y * shadows + s.highlightTint.y * highlights
        return OKLab.toLinearSRGB(SIMD3(lightness, a, b))
    }
}

/// Characteristic curve in log-log space: a straight line through mid gray that rolls
/// softly into paper white (shoulder) and into the print's maximum density (toe).
struct ToneCurve {
    private let stock: FilmStock
    private let contrast: SIMD3<Double>
    private let black: Double
    private let white: Double
    /// Display stops of mid gray before the rolloffs bend it.
    private let anchor: Double

    init(stock s: FilmStock) {
        stock = s
        contrast = s.contrast * s.channelContrast
        black = srgbToLinear(s.black)
        white = srgbToLinear(s.white)
        let target = log2((srgbToLinear(s.midGray) - black) / (white - black))
        anchor = Self.solve(target) { Self.rolloff($0, stock: s) }
    }

    /// Display-linear output for scene-linear input on one layer.
    func map(_ x: Double, channel i: Int) -> Double {
        let stops = log2(max(x, 1e-9) / 0.18) + stock.channelShift[i]
        let printed = Self.rolloff(anchor + contrast[i] * stops, stock: stock)
        return black + (white - black) * min(exp2(printed), 1)
    }

    private static func rolloff(_ stops: Double, stock s: FilmStock) -> Double {
        let shouldered = -softplus(-stops, s.shoulder)
        return -s.depth + softplus(shouldered + s.depth, s.toe)
    }

    private static func softplus(_ x: Double, _ k: Double) -> Double {
        x / k > 30 ? x : k * log1p(exp(x / k))
    }

    /// Inverts a monotonic function by bisection.
    private static func solve(_ target: Double, _ f: (Double) -> Double) -> Double {
        var low = target - 10
        var high = target + 10
        for _ in 0..<60 {
            let mid = (low + high) / 2
            if f(mid) < target { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }
}

enum OKLab {
    static func fromLinearSRGB(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = cbrt(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let s = cbrt(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        return SIMD3(
            0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func toLinearSRGB(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return SIMD3(
            4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
            -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
            -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }
}

func srgbToLinear(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

func smoothStep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}
