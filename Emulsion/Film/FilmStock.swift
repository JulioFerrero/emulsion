import simd

/// A range of hues (OKLab hue angle, degrees) that a stock renders in its own way.
struct HueBand {
    var center: Double
    var width: Double
    var hueShift: Double = 0
    var chroma: Double = 1
    var lightness: Double = 0
}

/// Contrast filters for black and white film: each passes its own color and holds back the rest.
/// Red turns blue sky nearly black, orange and yellow less so; green lightens foliage and deepens skin.
enum BWFilter: String, CaseIterable {
    case yellow = "Y2"
    case orange = "O"
    case red = "R25"
    case green = "G"

    /// Transmission of linear red, green and blue light.
    var transmission: SIMD3<Double> {
        switch self {
        case .yellow: return SIMD3(1, 0.9, 0.3)
        case .orange: return SIMD3(1, 0.55, 0.05)
        case .red: return SIMD3(1, 0.12, 0)
        case .green: return SIMD3(0.45, 1, 0.35)
        }
    }
}

struct FilmStock {
    var name: String
    var iso: Int
    var suffix: String = ""

    /// Color temperature the emulsion is balanced for. Film doesn't auto white balance.
    var balance: Float = 5500
    /// How much of the light's color survives to the final image. Slides are projected as shot (1);
    /// negatives are color-timed by the lab when printed, which takes most of a cast out.
    var colorCast: Float = 1

    // Characteristic curve of negative and print together, measured in stops.
    /// Slope of the straight-line section: display stops per scene stop.
    var contrast: Double = 1.1
    /// Display level (sRGB) that 18% gray prints at.
    var midGray: Double = 0.44
    /// Softness of the highlight rolloff into paper white.
    var shoulder: Double = 0.55
    /// Softness of the shadow rolloff into maximum density.
    var toe: Double = 1
    /// Stops between paper white and the deepest black the print holds.
    var depth: Double = 8.5
    /// Display floor and ceiling (sRGB levels).
    var black: Double = 0
    var white: Double = 1
    /// Per-layer exposure offset (stops) and contrast; their differences give color crossover.
    var channelShift: SIMD3<Double> = .zero
    var channelContrast: SIMD3<Double> = .one

    // Color rendering
    var saturation: Double = 1
    var highlightDesaturation: Double = 0.3
    var shadowDesaturation: Double = 0.2
    var hueBands: [HueBand] = []
    /// OKLab a/b offsets.
    var shadowTint: SIMD2<Double> = .zero
    var highlightTint: SIMD2<Double> = .zero
    /// Spectral sensitivity for black and white stocks.
    var monochrome: SIMD3<Double>? = nil
    /// OKLab chroma the dyes can reach; brighter colors are compressed softly toward it.
    var gamut: Double = 0.2

    var halation: Double = 0

    /// Grain RMS in stops, clump size in pixels at a 4032 px long edge, and how much dye color it carries.
    var grain: Double = 0.08
    var grainSize: Double = 2
    var grainColor: Double = 0.1

    /// The contrast filter on the lens, for black and white stocks.
    var filter: BWFilter?

    var label: String { "\(name) \(iso)\(suffix)" }
    /// The label with the filter, for the lab notes and anything cached per rendering.
    var fullLabel: String { filter.map { "\(label) \($0.rawValue)" } ?? label }

    /// The stock shot through `filter`. Through-the-lens metering makes up the light the filter takes,
    /// so the sensitivities keep their sum: gray stays gray, colors move.
    func through(_ filter: BWFilter?) -> FilmStock {
        guard let filter, let sensitivity = monochrome else { return self }
        var s = self
        let filtered = sensitivity * filter.transmission
        s.monochrome = filtered * ((sensitivity.x + sensitivity.y + sensitivity.z) / (filtered.x + filtered.y + filtered.z))
        s.filter = filter
        return s
    }

    func exposureIndex(push: Int) -> Int {
        push >= 0 ? iso << push : iso >> -push
    }

    /// Push processing builds contrast and grain; pulling softens both.
    func developed(push: Int) -> FilmStock {
        guard push != 0 else { return self }
        let p = Double(push)
        var s = self
        s.contrast *= 1 + 0.1 * p
        s.toe *= max(1 - 0.12 * p, 0.5)
        s.saturation *= 1 + 0.03 * p
        s.grain *= push > 0 ? 1 + 0.4 * p : 1 + 0.15 * p
        return s
    }
}

extension FilmStock {
    static let all: [FilmStock] = [
        .velvia, .provia, .chrome, .negative, .pro400H, .cinema, .tungsten, .eterna, .acros, .monoPush,
    ]

    // Neutral gray prints neutral on every color stock, at every exposure: a lab balances the print
    // on gray. Character lives in how hues render, with only a whisper of tint at the ends of the scale.

    /// Fuji's landscape slide: dense, vivid greens and blues, deep reds, almost no latitude.
    static let velvia: FilmStock = {
        var s = FilmStock(name: "VELVIA", iso: 50)
        s.contrast = 1.38
        s.midGray = 0.42
        s.shoulder = 0.36
        s.toe = 0.6
        s.depth = 10
        s.saturation = 1.18
        s.highlightDesaturation = 0.15
        s.shadowDesaturation = 0.1
        s.hueBands = [
            HueBand(center: 142, width: 40, hueShift: 6, chroma: 1.18, lightness: -0.03),
            HueBand(center: 255, width: 45, hueShift: -4, chroma: 1.12, lightness: -0.04),
            HueBand(center: 29, width: 28, hueShift: -4, chroma: 1.12, lightness: -0.02),
            HueBand(center: 58, width: 22, hueShift: -3, chroma: 1.06),
            HueBand(center: 100, width: 25, chroma: 1.08),
        ]
        s.shadowTint = SIMD2(0.002, 0)
        s.highlightTint = SIMD2(0.001, 0.003)
        s.grain = 0.045
        s.grainSize = 1.3
        s.gamut = 0.26
        return s
    }()

    /// Fuji's neutral slide: clean, honest color, crisp but not loud.
    static let provia: FilmStock = {
        var s = FilmStock(name: "PROVIA", iso: 100, suffix: "F")
        s.contrast = 1.24
        s.midGray = 0.44
        s.shoulder = 0.42
        s.toe = 0.8
        s.depth = 9.5
        s.saturation = 1.04
        s.highlightDesaturation = 0.2
        s.shadowDesaturation = 0.15
        s.hueBands = [
            HueBand(center: 264, width: 40, hueShift: -3, chroma: 1.05, lightness: -0.015),
            HueBand(center: 142, width: 35, hueShift: 2, chroma: 1.0),
            HueBand(center: 29, width: 25, chroma: 1.03),
        ]
        s.grain = 0.05
        s.grainSize = 1.4
        s.gamut = 0.23
        return s
    }()

    /// Documentary chrome: hard shadows, muted greens, cyan-leaning blues, deep reds.
    static let chrome: FilmStock = {
        var s = FilmStock(name: "CHROME", iso: 64)
        s.contrast = 1.3
        s.midGray = 0.42
        s.shoulder = 0.45
        s.toe = 0.7
        s.depth = 9.5
        s.white = 0.98
        s.saturation = 0.85
        s.highlightDesaturation = 0.35
        s.shadowDesaturation = 0.3
        s.hueBands = [
            HueBand(center: 142, width: 40, hueShift: -10, chroma: 0.72, lightness: -0.015),
            HueBand(center: 264, width: 45, hueShift: -15, chroma: 0.88, lightness: -0.03),
            HueBand(center: 29, width: 28, hueShift: 3, chroma: 1.08, lightness: -0.03),
            HueBand(center: 105, width: 25, hueShift: -5, chroma: 0.85),
        ]
        s.highlightTint = SIMD2(0.001, 0.004)
        s.grain = 0.05
        s.grainSize = 1.4
        s.gamut = 0.18
        return s
    }()

    /// Portrait negative: gentle contrast, huge highlight latitude, warm skin, pastel highlights.
    static let negative: FilmStock = {
        var s = FilmStock(name: "NEGATIVE", iso: 400)
        s.contrast = 1.03
        s.midGray = 0.46
        s.shoulder = 0.7
        s.toe = 1
        s.depth = 8.5
        s.black = 0.008
        s.white = 0.985
        s.saturation = 0.98
        s.highlightDesaturation = 0.4
        s.shadowDesaturation = 0.35
        s.hueBands = [
            HueBand(center: 58, width: 25, hueShift: 3, chroma: 1.06, lightness: 0.01),
            HueBand(center: 142, width: 40, hueShift: -12, chroma: 0.85),
            HueBand(center: 264, width: 45, hueShift: -10, chroma: 0.9, lightness: 0.01),
        ]
        s.shadowTint = SIMD2(0.001, 0.002)
        s.highlightTint = SIMD2(0.002, 0.005)
        s.grain = 0.1
        s.grainSize = 2.2
        s.grainColor = 0.15
        s.colorCast = 0.3
        return s
    }()

    /// Fuji's portrait negative: airy and pastel, minty greens, cyan skies, cooler and pinker skin than Kodak.
    static let pro400H: FilmStock = {
        var s = FilmStock(name: "PRO", iso: 400, suffix: "H")
        s.contrast = 0.98
        s.midGray = 0.47
        s.shoulder = 0.78
        s.toe = 1.05
        s.depth = 8.2
        s.black = 0.01
        s.white = 0.985
        s.saturation = 0.9
        s.highlightDesaturation = 0.45
        s.shadowDesaturation = 0.35
        s.hueBands = [
            HueBand(center: 142, width: 45, hueShift: 10, chroma: 0.85, lightness: 0.02),
            HueBand(center: 250, width: 50, hueShift: -10, chroma: 0.9, lightness: 0.015),
            HueBand(center: 55, width: 22, hueShift: -3, chroma: 0.95),
            HueBand(center: 100, width: 22, hueShift: 4, chroma: 0.9),
        ]
        s.shadowTint = SIMD2(-0.002, 0)
        s.highlightTint = SIMD2(0.001, 0.002)
        s.grain = 0.09
        s.grainSize = 2
        s.grainColor = 0.15
        s.gamut = 0.16
        s.colorCast = 0.3
        return s
    }()

    /// Motion picture daylight stock: soft, restrained color, skin that stays alive.
    static let cinema: FilmStock = {
        var s = FilmStock(name: "CINEMA", iso: 250, suffix: "D")
        s.contrast = 1.04
        s.midGray = 0.43
        s.shoulder = 0.7
        s.toe = 1
        s.depth = 8.5
        s.black = 0.006
        s.white = 0.975
        s.saturation = 0.85
        s.highlightDesaturation = 0.4
        s.shadowDesaturation = 0.35
        s.hueBands = [
            HueBand(center: 58, width: 25, chroma: 1.08, lightness: 0.005),
            HueBand(center: 250, width: 50, hueShift: -12, chroma: 0.85),
            HueBand(center: 142, width: 40, hueShift: -6, chroma: 0.75),
        ]
        s.highlightTint = SIMD2(0.002, 0.004)
        s.grain = 0.08
        s.grainSize = 1.9
        s.gamut = 0.17
        s.colorCast = 0.35
        return s
    }()

    /// Tungsten-balanced motion picture stock without its anti-halation layer.
    /// In daylight it goes cool; the lab scan takes most of that out, an 85 filter all of it.
    static let tungsten: FilmStock = {
        var s = FilmStock(name: "TUNGSTEN", iso: 800, suffix: "T")
        s.balance = 3200
        s.contrast = 1.05
        s.midGray = 0.45
        s.shoulder = 0.65
        s.toe = 1.1
        s.depth = 8
        s.black = 0.01
        s.white = 0.98
        s.shadowDesaturation = 0.35
        s.hueBands = [
            HueBand(center: 29, width: 25, chroma: 1.12, lightness: -0.01),
            HueBand(center: 220, width: 50, hueShift: -6, chroma: 1.05),
        ]
        s.shadowTint = SIMD2(-0.001, -0.002)
        s.highlightTint = SIMD2(0.002, 0.002)
        s.halation = 0.55
        s.grain = 0.14
        s.grainSize = 2.6
        s.grainColor = 0.15
        s.colorCast = 0.25
        return s
    }()

    /// Fuji's tungsten cinema stock: flat, quiet, low saturation, a cool calm in the greens and blues.
    static let eterna: FilmStock = {
        var s = FilmStock(name: "ETERNA", iso: 500, suffix: "T")
        s.balance = 3200
        s.contrast = 0.94
        s.midGray = 0.42
        s.shoulder = 0.8
        s.toe = 1.15
        s.depth = 7.8
        s.black = 0.014
        s.white = 0.965
        s.saturation = 0.72
        s.highlightDesaturation = 0.45
        s.shadowDesaturation = 0.4
        s.hueBands = [
            HueBand(center: 142, width: 45, hueShift: 8, chroma: 0.72),
            HueBand(center: 250, width: 50, hueShift: -10, chroma: 0.82),
            HueBand(center: 58, width: 25, chroma: 1.05, lightness: 0.005),
        ]
        s.shadowTint = SIMD2(-0.002, -0.002)
        s.halation = 0.12
        s.grain = 0.11
        s.grainSize = 2.3
        s.grainColor = 0.12
        s.gamut = 0.15
        s.colorCast = 0.25
        return s
    }()

    /// Fuji's fine-grain black and white: smooth tones, deep blacks, a touch less red-sensitive.
    static let acros: FilmStock = {
        var s = FilmStock(name: "ACROS", iso: 100)
        s.monochrome = SIMD3(0.27, 0.6, 0.13)
        s.contrast = 1.2
        s.shoulder = 0.5
        s.toe = 0.8
        s.depth = 9.5
        s.grain = 0.05
        s.grainSize = 1.3
        s.grainColor = 0
        return s
    }()

    /// Black and white rated fast: punchy, gritty, visible grain.
    static let monoPush: FilmStock = {
        var s = FilmStock(name: "MONO", iso: 400)
        s.monochrome = SIMD3(0.38, 0.55, 0.07)
        s.contrast = 1.3
        s.midGray = 0.43
        s.shoulder = 0.45
        s.toe = 0.75
        s.depth = 9.5
        s.grain = 0.11
        s.grainSize = 2.4
        s.grainColor = 0
        return s
    }()
}
