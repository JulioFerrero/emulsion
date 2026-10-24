import CoreImage
import Foundation

/// Develops scene-linear images through a film stock: halation, shaper, grain, then the stock's LUT.
final class FilmRenderer {
    enum Mode {
        case preview
        case full
    }

    /// RMS of the grain kernel's noise, used to express grain in stops.
    static let grainNoiseRMS = 0.163

    private var cubes: [String: Data] = [:]
    private let lock = NSLock()

    func prewarm() {
        DispatchQueue.global(qos: .utility).async {
            for stock in FilmStock.all {
                _ = self.cube(for: stock, push: 0)
            }
        }
    }

    /// `push` is in stops: the frame was underexposed by that much at capture and development makes it up.
    /// `seed` moves the grain field so no two frames share the same grain.
    /// `grainScale` enlarges grain for formats smaller than a 36 mm still frame, like a 25 mm cinema frame.
    /// `mist` is the strength of a diffusion filter on the lens, 0 for none.
    func apply(_ stock: FilmStock, push: Int, to scene: CIImage, mode: Mode, seed: CGPoint,
               grainScale: Double = 1, mist: Double = 0) -> CIImage {
        let film = stock.developed(push: push)
        let extent = scene.extent
        let longEdge = max(extent.width, extent.height)
        let gain = exp2(Double(push))
        var image = scene

        if mist > 0 {
            image = diffusion(image, strength: mist, longEdge: longEdge)
        }

        if film.halation > 0 {
            image = halation(image, strength: film.halation, threshold: 0.9 / gain, radius: 0.008 * longEdge)
        }

        image = FilmKernels.shaper.apply(extent: extent, arguments: [
            image, Float(gain), Float(Shaper.floor), Float(Shaper.range),
        ]) ?? image

        // Grain finer than a pixel averages out when the frame is viewed small, as in the preview.
        let size = film.grainSize * grainScale * Double(longEdge) / 4032
        let amount = film.grain / (Shaper.range * Self.grainNoiseRMS) * min(size, 1)
        if amount > 0 {
            image = FilmKernels.grain.apply(extent: extent, arguments: [
                image,
                Float(amount),
                Float(max(size, 1)),
                Float(film.grainColor),
                CIVector(x: seed.x, y: seed.y),
            ]) ?? image
        }

        return image.applyingFilter("CIColorCube", parameters: [
            "inputCubeDimension": FilmLUT.dimension,
            "inputCubeData": cube(for: stock, push: push),
        ])
    }

    /// Paints sharp edges of `scene` over `film` to show what's in focus.
    func peaking(film: CIImage, scene: CIImage) -> CIImage {
        FilmKernels.peaking.apply(
            extent: film.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -1, dy: -1) },
            arguments: [film, scene, Float(0.06)]) ?? film
    }

    /// Stripes over what's within a few percent of clipping on the print.
    func zebras(_ film: CIImage, phase: Double) -> CIImage {
        FilmKernels.zebra.apply(extent: film.extent, arguments: [film, Float(0.88), Float(phase)]) ?? film
    }

    /// A Pro-Mist style filter: a share of all the light scattered into a tight glow and a wide halo, with
    /// nothing added or lost. Highlights bloom and the shadows around them lift; open shadows stay deep.
    private func diffusion(_ image: CIImage, strength: Double, longEdge: CGFloat) -> CIImage {
        let clamped = image.clampedToExtent()
        let tight = clamped.applyingGaussianBlur(sigma: Double(0.004 * longEdge)).cropped(to: image.extent)
        let wide = clamped.applyingGaussianBlur(sigma: Double(0.02 * longEdge)).cropped(to: image.extent)
        return FilmKernels.diffuse.apply(extent: image.extent, arguments: [image, tight, wide, Float(strength)]) ?? image
    }

    private func halation(_ image: CIImage, strength: Double, threshold: Double, radius: CGFloat) -> CIImage {
        guard let bright = FilmKernels.highlights.apply(extent: image.extent, arguments: [image, Float(threshold)]) else {
            return image
        }
        let glow = bright.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: image.extent)
        let tint = CIVector(x: strength, y: 0.24 * strength, z: 0.06 * strength)
        return FilmKernels.addGlow.apply(extent: image.extent, arguments: [image, glow, tint]) ?? image
    }

    private func cube(for stock: FilmStock, push: Int) -> Data {
        let key = "\(stock.fullLabel) \(push)"
        lock.lock()
        if let data = cubes[key] {
            lock.unlock()
            return data
        }
        lock.unlock()

        let data = FilmLUT.make(for: stock.developed(push: push)).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        cubes[key] = data
        lock.unlock()
        return data
    }
}

enum FilmKernels {
    static let shaper = load("shaper")
    static let highlights = load("highlights")
    static let addGlow = load("addGlow")
    static let grain = load("grain")
    static let zebra = load("zebra")
    static let diffuse = load("diffuse")
    static let addFrames = load("addFrames")
    static let accumulateFrame = load("accumulateFrame")
    static let resolveMerge = load("resolveMerge")
    static let resample: CIKernel = {
        do {
            return try CIKernel(functionName: "resample", fromMetalLibraryData: library)
        } catch {
            fatalError("Could not load kernel resample: \(error)")
        }
    }()
    static let sharpenRoot = load("sharpenRoot")
    static let peaking: CIKernel = {
        do {
            return try CIKernel(functionName: "peaking", fromMetalLibraryData: library)
        } catch {
            fatalError("Could not load kernel peaking: \(error)")
        }
    }()

    private static let library: Data = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url) else {
            fatalError("Core Image kernels are missing from the bundle")
        }
        return data
    }()

    private static func load(_ name: String) -> CIColorKernel {
        do {
            return try CIColorKernel(functionName: name, fromMetalLibraryData: library)
        } catch {
            fatalError("Could not load kernel \(name): \(error)")
        }
    }
}
