import CoreGraphics

enum FilmFormat: String, CaseIterable {
    case leica = "135"
    case sixFourFive = "645"
    case square = "6×6"
    case xpan = "XPAN"

    /// Long side over short side.
    var ratio: CGFloat {
        switch self {
        case .leica: return 3 / 2
        case .sixFourFive: return 4 / 3
        case .square: return 1
        case .xpan: return 65 / 24
        }
    }
}

/// Crop zoom on the 6s's single lens, named by 35mm-equivalent focal length.
enum FocalLength: Int, CaseIterable {
    case wide = 28
    case moderate = 35
    case normal = 50

    var label: String { "\(rawValue)MM" }
    var crop: CGFloat { CGFloat(rawValue) / CGFloat(FocalLength.wide.rawValue) }
}

enum Framing {
    /// The part of `rect` a format keeps, centered, whichever way the frame is held.
    static func format(_ rect: CGRect, _ format: FilmFormat) -> CGRect {
        self.format(rect, ratio: format.ratio)
    }

    /// `ratio` is long side over short side.
    static func format(_ rect: CGRect, ratio: CGFloat) -> CGRect {
        let long = max(rect.width, rect.height)
        let short = min(rect.width, rect.height)
        var keepLong = long
        var keepShort = short
        if ratio >= long / short {
            keepShort = long / ratio
        } else {
            keepLong = short * ratio
        }
        let size = rect.width >= rect.height
            ? CGSize(width: keepLong, height: keepShort)
            : CGSize(width: keepShort, height: keepLong)
        return centered(size, in: rect)
    }

    /// The center of `rect` a focal length sees.
    static func zoom(_ rect: CGRect, _ focal: FocalLength) -> CGRect {
        zoom(rect, factor: focal.crop)
    }

    static func zoom(_ rect: CGRect, factor: CGFloat) -> CGRect {
        centered(CGSize(width: rect.width / factor, height: rect.height / factor), in: rect)
    }

    private static func centered(_ size: CGSize, in rect: CGRect) -> CGRect {
        CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
               width: size.width, height: size.height).integral
    }
}
