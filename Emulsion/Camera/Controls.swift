import Foundation

enum CaptureMode: String, CaseIterable {
    case single = "×1"
    /// Four equal RAW frames, averaged: about two stops less noise.
    case stack = "×4"
    /// A −2 / 0 / +2 RAW bracket merged into one frame with more latitude.
    case range = "HDR"

    /// Exposure of each frame, in stops relative to the metered exposure.
    var offsets: [Float] {
        switch self {
        case .single: return [0]
        case .stack: return [0, 0, 0, 0]
        case .range: return [-2, 0, 2]
        }
    }
}

enum ShutterSpeed {
    /// Third-stop speeds from 1/8000 to the 6s's longest exposure, 1/3 s, fastest first.
    static let all: [Double] = [
        8000, 6400, 5000, 4000, 3200, 2500, 2000, 1600, 1250, 1000, 800, 640, 500, 400, 320, 250, 200, 160,
        125, 100, 80, 60, 50, 40, 30, 25, 20, 15, 13, 10, 8, 6, 5, 4, 3,
    ].map { 1 / $0 }

    static func label(_ seconds: Double) -> String {
        "1/\(Int((1 / seconds).rounded()))"
    }

    static func nearest(to seconds: Double) -> Int {
        all.indices.min { abs(log2(all[$0] / seconds)) < abs(log2(all[$1] / seconds)) } ?? 0
    }
}

/// Lens position against distance for the 6s's 4.15 mm lens. Position 0 is the closest focus, 10 cm.
/// A voice-coil lens moves in proportion to its extension, f² / (d − f), which reaches zero at infinity;
/// where infinity falls on the 0–1 scale isn't published, and varies from unit to unit.
enum FocusScale {
    static let infinity: Float = 0.9
    static let closest: Float = 0.1
    private static let focal: Float = 0.00415

    private static func extension_(_ meters: Float) -> Float {
        focal * focal / (meters - focal)
    }

    static func position(meters: Float) -> Float {
        infinity * (1 - extension_(meters) / extension_(closest))
    }

    static func meters(_ position: Float) -> Float {
        guard position < infinity else { return .infinity }
        let e = (1 - position / infinity) * extension_(closest)
        return focal * focal / e + focal
    }

    static func label(_ position: Float) -> String {
        let m = meters(position)
        if m >= 20 { return "∞" }
        if m < 1 { return "\(Int((m * 100).rounded())) CM" }
        if m < 3 { return String(format: "%.1f M", m) }
        return "\(Int(m.rounded())) M"
    }
}

/// Video frame shapes, by aspect ratio.
enum VideoAspect: String, CaseIterable {
    case hd = "16:9"
    case flat = "1.85"
    case scope = "2.39"
    case square = "1:1"
    /// Super 8: the full 4:3 sensor at 18 frames a second, with a tiny frame's grain, softness and gate weave.
    case superEight = "S8"

    var ratio: CGFloat {
        switch self {
        case .hd: return 16 / 9
        case .flat: return 1.85
        case .scope: return 2.39
        case .square: return 1
        case .superEight: return 4 / 3
        }
    }

    /// Shape of the sensor mode to record from. Square and Super 8 use the full 4:3 sensor height;
    /// the wide shapes come from the 16:9 4K mode.
    var sensorRatio: CGFloat {
        self == .square || self == .superEight ? 4 / 3 : 16 / 9
    }

    /// Recorded size: 1920 wide, an even number of lines tall; square and Super 8 are 1440 wide or tall,
    /// about as many pixels as 1080p.
    var size: CGSize {
        switch self {
        case .square: return CGSize(width: 1440, height: 1440)
        case .superEight: return CGSize(width: 1440, height: 1080)
        default: return CGSize(width: 1920, height: (1920 / ratio / 2).rounded() * 2)
        }
    }

    /// Super 8 runs at its own speed.
    var fixedFrameRate: Int? { self == .superEight ? 18 : nil }

    /// Grain grows as the frame shrinks: a 36 mm still frame is 1, Super 35 cinema about 1.4, Super 8 about 5.
    var grainScale: Double { self == .superEight ? 5 : 36 / 24.9 }

    /// The 120 fps mode virtual ND needs is 16:9.
    var allowsVirtualND: Bool { sensorRatio == 16 / 9 }
}

enum FrameRate: Int, CaseIterable {
    case cinema = 24
    case pal = 25
    case ntsc = 30

    var label: String { "\(rawValue)P" }
}

/// The shutter as cinema cameras express it: how much of each frame's time it stays open, in degrees.
/// 180° gives motion the blur the eye reads as film; narrower is crisper and more staccato.
enum ShutterAngle: Int, CaseIterable {
    case standard = 180
    case narrow = 90
    case staccato = 45
    case open = 360

    var label: String { "\(rawValue)°" }

    func duration(fps: Int) -> Double {
        Double(rawValue) / 360 / Double(fps)
    }
}

/// Diffusion filter strengths, named like the glass: 1/8 is a whisper, 1/2 is dreamy.
enum Mist: Int, CaseIterable {
    case off = 0
    case eighth = 8
    case quarter = 4
    case half = 2

    var strength: Double {
        switch self {
        case .off: return 0
        case .eighth: return 0.12
        case .quarter: return 0.22
        case .half: return 0.38
        }
    }

    var label: String { self == .off ? "MIST" : "MIST 1/\(rawValue)" }
}
