import Accelerate

/// Global translation between two frames by phase correlation: whiten the cross-power spectrum of two
/// patches and the inverse transform peaks at their offset. A 512×512 patch takes milliseconds on the CPU.
final class PhaseCorrelator {
    struct Spectrum {
        fileprivate var real: [Float]
        fileprivate var imag: [Float]
    }

    /// Side of the square patch, a power of two.
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: [Float]

    init(size: Int = 512) {
        self.size = size
        log2n = vDSP_Length(log2(Double(size)).rounded())
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // A Hann window, so the patch's edges don't correlate with each other.
        let line = (0..<size).map { 0.5 - 0.5 * cos(2 * Float.pi * (Float($0) + 0.5) / Float(size)) }
        window = (0..<size * size).map { line[$0 % size] * line[$0 / size] }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// `patch` is size × size, row-major.
    func spectrum(_ patch: [Float]) -> Spectrum {
        var real = vDSP.multiply(vDSP.add(-vDSP.mean(patch), patch), window)
        var imag = [Float](repeating: 0, count: size * size)
        transform(&real, &imag, direction: kFFTDirection_Forward)
        return Spectrum(real: real, imag: imag)
    }

    /// Where `moving`'s content sits relative to `reference`'s, in patch pixels along its rows and columns,
    /// and the peak's strength: near 1 for the same picture, near 0 for unrelated ones.
    func offset(of moving: Spectrum, from reference: Spectrum) -> (x: Float, y: Float, strength: Float) {
        let n = size * size
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        for k in 0..<n {
            // conj(reference) · moving, whitened so only phase is left.
            let re = reference.real[k] * moving.real[k] + reference.imag[k] * moving.imag[k]
            let im = reference.real[k] * moving.imag[k] - reference.imag[k] * moving.real[k]
            let magnitude = max((re * re + im * im).squareRoot(), 1e-20)
            real[k] = re / magnitude
            imag[k] = im / magnitude
        }
        transform(&real, &imag, direction: kFFTDirection_Inverse)

        var peak: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(real, 1, &peak, &index, vDSP_Length(n))
        let px = Int(index) % size
        let py = Int(index) / size
        func at(_ x: Int, _ y: Int) -> Float { real[((y + size) % size) * size + (x + size) % size] }
        // Parabola through the peak and its neighbours, for the sub-pixel part.
        func refine(_ minus: Float, _ center: Float, _ plus: Float) -> Float {
            let denominator = minus - 2 * center + plus
            return abs(denominator) < 1e-12 ? 0 : 0.5 * (minus - plus) / denominator
        }
        var x = Float(px) + refine(at(px - 1, py), peak, at(px + 1, py))
        var y = Float(py) + refine(at(px, py - 1), peak, at(px, py + 1))
        if x > Float(size / 2) { x -= Float(size) }
        if y > Float(size / 2) { y -= Float(size) }
        return (x, y, peak / Float(n))
    }

    private func transform(_ real: inout [Float], _ imag: inout [Float], direction: Int) {
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, 0, log2n, log2n, FFTDirection(direction))
            }
        }
    }
}
