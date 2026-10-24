import Foundation
import simd

/// What a raw developer needs from a DNG: sensor levels, color calibration, white balance, lens correction.
/// Also decodes the Bayer data itself (lossless JPEG tiles, as AVFoundation writes it) for tools on the Mac;
/// on the phone the Bayer data comes straight from the capture instead.
struct DNG {
    var width: Int
    var height: Int
    var blackLevel: Double
    var whiteLevel: Double
    /// XYZ to camera, for illuminant A (tungsten) and D65 (daylight).
    var colorMatrixA: simd_double3x3
    var colorMatrixD65: simd_double3x3
    /// Camera RGB of a neutral surface under the light at capture: the white balance.
    var asShotNeutral: SIMD3<Double>
    var baselineExposure: Double
    /// FixVignetteRadial: gain = 1 + k0 r² + k1 r⁴ + … around `vignetteCenter`, r = 1 at the farthest corner.
    var vignette: [Double] = []
    var vignetteCenter = SIMD2<Double>(0.5, 0.5)
    /// Noise variance as S·x + O for a normalized signal x.
    var noiseProfile = SIMD2<Double>(0, 0)
    var orientation: Int = 1
    /// 0 red, 1 green, 2 blue, over the 2×2 repeat, row by row.
    var cfaPattern: [Int] = []
    var isRGGB: Bool { cfaPattern == [0, 1, 1, 2] }

    /// Typical values for this sensor, for warming up the developer before the first real frame.
    init(standInWidth width: Int, height: Int) {
        self.width = width
        self.height = height
        blackLevel = 528
        whiteLevel = 4095
        colorMatrixA = simd_double3x3(rows: [
            SIMD3(1.3147, -0.5911, -0.2610), SIMD3(-0.3600, 1.3403, 0.1702), SIMD3(-0.0072, 0.1015, 0.7427),
        ])
        colorMatrixD65 = simd_double3x3(rows: [
            SIMD3(0.6802, -0.2149, -0.0108), SIMD3(-0.6242, 1.2545, 0.3125), SIMD3(-0.1168, 0.1355, 0.5959),
        ])
        asShotNeutral = SIMD3(0.55, 1, 0.64)
        baselineExposure = -0.5
        vignette = [1.0049, 2.0881, -4.5230, 5.6218, -2.1177]
        cfaPattern = [0, 1, 1, 2]
    }

    private var tiles: [(offset: Int, count: Int)] = []
    private var tileSize = (width: 0, height: 0)
    private var compression = 1
    private var data = Data()

    init?(data: Data) {
        guard let tiff = TIFF(data), let ifd = tiff.firstIFD() else { return nil }
        guard let width = ifd.int(256), let height = ifd.int(257),
              let white = ifd.doubles(50717)?.first,
              let matrixA = ifd.doubles(50721), matrixA.count == 9,
              let matrixD65 = ifd.doubles(50722), matrixD65.count == 9,
              let neutral = ifd.doubles(50728), neutral.count == 3 else { return nil }
        // The matrices are tagged with their illuminants; Apple writes A (17) first and D65 (21) second.
        self.width = width
        self.height = height
        blackLevel = ifd.doubles(50714)?.first ?? 0
        whiteLevel = white
        colorMatrixA = Self.matrix(matrixA)
        colorMatrixD65 = Self.matrix(matrixD65)
        if ifd.int(50778) == 21, ifd.int(50779) == 17 {
            swap(&colorMatrixA, &colorMatrixD65)
        }
        asShotNeutral = SIMD3(neutral[0], neutral[1], neutral[2])
        baselineExposure = ifd.doubles(50730)?.first ?? 0
        orientation = ifd.int(274) ?? 1
        cfaPattern = ifd.ints(33422) ?? []
        if let noise = ifd.doubles(51041), noise.count >= 2 {
            noiseProfile = SIMD2(noise[0], noise[1])
        }
        if let opcodes = ifd.bytes(51022) {
            readOpcodes(opcodes)
        }

        compression = ifd.int(259) ?? 1
        if let offsets = ifd.ints(324), let counts = ifd.ints(325) {
            tiles = zip(offsets, counts).map { ($0, $1) }
            tileSize = (ifd.int(322) ?? width, ifd.int(323) ?? height)
        } else if let offsets = ifd.ints(273), let counts = ifd.ints(279) {
            tiles = zip(offsets, counts).map { ($0, $1) }
            tileSize = (width, ifd.int(278) ?? height)
        }
        self.data = data
    }

    private static func matrix(_ v: [Double]) -> simd_double3x3 {
        // DNG matrices are row-major; simd is column-major.
        simd_double3x3(rows: [SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8])])
    }

    private mutating func readOpcodes(_ list: Data) {
        // Opcode lists are big-endian whatever the file's byte order.
        func u32(_ at: Int) -> UInt32 { list.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) } }
        func f64(_ at: Int) -> Double {
            Double(bitPattern: list.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt64.self)) })
        }
        guard list.count >= 4 else { return }
        var position = 4
        for _ in 0..<u32(0) {
            guard position + 16 <= list.count else { return }
            let id = u32(position)
            let size = Int(u32(position + 12))
            let body = position + 16
            // 3: FixVignetteRadial, five coefficients then the optical center.
            if id == 3, size >= 56 {
                vignette = (0..<5).map { f64(body + $0 * 8) }
                vignetteCenter = SIMD2(f64(body + 40), f64(body + 48))
            }
            position = body + size
        }
    }

    /// One tile of the mosaic and where it sits, row-major.
    func decodeTile(_ index: Int) -> (samples: [UInt16], x: Int, y: Int, width: Int, height: Int)? {
        guard index < tiles.count else { return nil }
        let tile = tiles[index]
        let bytes = data.subdata(in: tile.offset..<(tile.offset + tile.count))
        let samples = compression == 7
            ? LosslessJPEG.decode(bytes)
            : bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        guard let samples else { return nil }
        let across = (width + tileSize.width - 1) / tileSize.width
        return (samples, (index % across) * tileSize.width, (index / across) * tileSize.height, tileSize.width, tileSize.height)
    }

    /// The raw mosaic, row-major, top row first.
    func decodeBayer() -> [UInt16]? {
        guard compression == 7 || compression == 1 else { return nil }
        var out = [UInt16](repeating: 0, count: width * height)
        let across = (width + tileSize.width - 1) / tileSize.width
        for (index, tile) in tiles.enumerated() {
            let x0 = (index % across) * tileSize.width
            let y0 = (index / across) * tileSize.height
            let bytes = data.subdata(in: tile.offset..<(tile.offset + tile.count))
            let samples: [UInt16]
            if compression == 7 {
                guard let decoded = LosslessJPEG.decode(bytes) else { return nil }
                samples = decoded
            } else {
                samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
            }
            for row in 0..<tileSize.height where y0 + row < height {
                for col in 0..<tileSize.width where x0 + col < width {
                    let i = row * tileSize.width + col
                    if i < samples.count {
                        out[(y0 + row) * width + x0 + col] = samples[i]
                    }
                }
            }
        }
        return out
    }
}

/// Just enough TIFF to read a DNG's first image directory.
private struct TIFF {
    struct Entry {
        var type: Int
        var count: Int
        var offset: Int
    }

    struct Directory {
        let tiff: TIFF
        let entries: [Int: Entry]

        func int(_ tag: Int) -> Int? { ints(tag)?.first }

        func ints(_ tag: Int) -> [Int]? {
            guard let e = entries[tag] else { return nil }
            switch e.type {
            case 3: return (0..<e.count).map { Int(tiff.u16(e.offset + $0 * 2)) }
            case 4, 13: return (0..<e.count).map { Int(tiff.u32(e.offset + $0 * 4)) }
            case 1, 7: return (0..<e.count).map { Int(tiff.data[e.offset + $0]) }
            default: return nil
            }
        }

        func doubles(_ tag: Int) -> [Double]? {
            guard let e = entries[tag] else { return nil }
            switch e.type {
            case 5: return (0..<e.count).map { Double(tiff.u32(e.offset + $0 * 8)) / Double(max(tiff.u32(e.offset + $0 * 8 + 4), 1)) }
            case 10:
                return (0..<e.count).map {
                    Double(Int32(bitPattern: tiff.u32(e.offset + $0 * 8))) / Double(max(Int32(bitPattern: tiff.u32(e.offset + $0 * 8 + 4)), 1))
                }
            case 11: return (0..<e.count).map { Double(Float(bitPattern: tiff.u32(e.offset + $0 * 4))) }
            case 12: return (0..<e.count).map { Double(bitPattern: tiff.u64(e.offset + $0 * 8)) }
            default: return ints(tag)?.map(Double.init)
            }
        }

        func bytes(_ tag: Int) -> Data? {
            guard let e = entries[tag], e.offset + e.count <= tiff.data.count else { return nil }
            return tiff.data.subdata(in: e.offset..<(e.offset + e.count))
        }
    }

    let data: Data
    let littleEndian: Bool

    init?(_ data: Data) {
        guard data.count > 8 else { return nil }
        self.data = data
        littleEndian = data[0] == 0x49
    }

    func u16(_ at: Int) -> UInt16 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt16.self) }
        return littleEndian ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
    }

    func u32(_ at: Int) -> UInt32 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        return littleEndian ? UInt32(littleEndian: v) : UInt32(bigEndian: v)
    }

    func u64(_ at: Int) -> UInt64 {
        let v = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
        return littleEndian ? UInt64(littleEndian: v) : UInt64(bigEndian: v)
    }

    func firstIFD() -> Directory? {
        let start = Int(u32(4))
        guard start + 2 <= data.count else { return nil }
        let sizes = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4]
        var entries: [Int: Entry] = [:]
        for i in 0..<Int(u16(start)) {
            let at = start + 2 + i * 12
            let type = Int(u16(at + 2))
            let count = Int(u32(at + 4))
            let size = (sizes[type] ?? 1) * count
            // Values of four bytes or fewer sit in the entry itself.
            let offset = size <= 4 ? at + 8 : Int(u32(at + 8))
            entries[Int(u16(at))] = Entry(type: type, count: count, offset: offset)
        }
        return Directory(tiff: self, entries: entries)
    }
}

/// Lossless JPEG (ITU T.81 process 14), the compression inside DNG tiles.
enum LosslessJPEG {
    private struct Huffman {
        /// Code length and value for every 16-bit prefix.
        var lookup = [UInt32](repeating: 0, count: 1 << 16)
    }

    static func decode(_ data: Data) -> [UInt16]? {
        data.withUnsafeBytes { raw -> [UInt16]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var position = 2
            var tables = [Int: Huffman]()
            var precision = 0, height = 0, width = 0, components = 0
            var componentTables = [Int]()
            var predictor = 1, pointTransform = 0

            func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }

            // Markers up to the start of scan.
            while position + 4 <= bytes.count {
                guard bytes[position] == 0xFF else { return nil }
                let marker = bytes[position + 1]
                let length = u16(position + 2)
                let body = position + 4
                switch marker {
                case 0xC4:
                    var p = body
                    while p < position + 2 + length {
                        let id = Int(bytes[p] & 0x0F)
                        var counts = [Int](repeating: 0, count: 17)
                        for i in 1...16 { counts[i] = Int(bytes[p + i]) }
                        var v = p + 17
                        var table = Huffman()
                        var code = 0
                        for bits in 1...16 {
                            for _ in 0..<counts[bits] {
                                let value = UInt32(bytes[v])
                                v += 1
                                let first = code << (16 - bits)
                                let span = 1 << (16 - bits)
                                for k in 0..<span {
                                    table.lookup[first + k] = UInt32(bits) << 8 | value
                                }
                                code += 1
                            }
                            code <<= 1
                        }
                        tables[id] = table
                        p = v
                    }
                case 0xC3:
                    precision = Int(bytes[body])
                    height = u16(body + 1)
                    width = u16(body + 3)
                    components = Int(bytes[body + 5])
                case 0xDA:
                    let count = Int(bytes[body])
                    for c in 0..<count {
                        componentTables.append(Int(bytes[body + 2 + c * 2] >> 4))
                    }
                    predictor = Int(bytes[body + 1 + count * 2])
                    pointTransform = Int(bytes[body + 3 + count * 2] & 0x0F)
                    position = position + 2 + length
                    return scan(bytes, from: position, tables: tables, width: width, height: height,
                                components: components, componentTables: componentTables,
                                precision: precision, predictor: predictor, pointTransform: pointTransform)
                default:
                    break
                }
                position += 2 + length
            }
            return nil
        }
    }

    private static func scan(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, tables: [Int: Huffman],
        width: Int, height: Int, components: Int, componentTables: [Int],
        precision: Int, predictor: Int, pointTransform: Int
    ) -> [UInt16]? {
        let lookups = componentTables.map { tables[$0] ?? tables.values.first! }
        let rowLength = width * components
        var out = [UInt16](repeating: 0, count: rowLength * height)
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var position = start

        func fill() {
            while bitCount <= 56 {
                var byte: UInt8 = 0
                if position < bytes.count {
                    byte = bytes[position]
                    position += 1
                    // 0xFF 0x00 is a stuffed 0xFF; any other 0xFF is a marker, past the data.
                    if byte == 0xFF {
                        if position < bytes.count, bytes[position] == 0 {
                            position += 1
                        } else {
                            position = bytes.count
                            byte = 0
                        }
                    }
                }
                bitBuffer |= UInt64(byte) << (56 - bitCount)
                bitCount += 8
            }
        }

        func bits(_ n: Int) -> Int {
            if n == 0 { return 0 }
            if bitCount < n { fill() }
            let v = Int(bitBuffer >> (64 - n))
            bitBuffer <<= UInt64(n)
            bitCount -= n
            return v
        }

        func difference(_ table: Huffman) -> Int {
            if bitCount < 32 { fill() }
            let entry = table.lookup[Int(bitBuffer >> 48)]
            let length = Int(entry >> 8)
            let category = Int(entry & 0xFF)
            bitBuffer <<= UInt64(length)
            bitCount -= length
            if category == 0 { return 0 }
            if category == 16 { return 32768 }
            let v = bits(category)
            return v < 1 << (category - 1) ? v - (1 << category) + 1 : v
        }

        let initial = 1 << (precision - pointTransform - 1)
        return out.withUnsafeMutableBufferPointer { o -> [UInt16]? in
            for row in 0..<height {
                let base = row * rowLength
                for col in 0..<width {
                    for c in 0..<components {
                        let i = base + col * components + c
                        let prediction: Int
                        if row == 0 && col == 0 {
                            prediction = initial
                        } else if row == 0 {
                            prediction = Int(o[i - components])
                        } else if col == 0 {
                            prediction = Int(o[i - rowLength])
                        } else {
                            let a = Int(o[i - components]), b = Int(o[i - rowLength]), cc = Int(o[i - rowLength - components])
                            switch predictor {
                            case 2: prediction = b
                            case 3: prediction = cc
                            case 4: prediction = a + b - cc
                            case 5: prediction = a + ((b - cc) >> 1)
                            case 6: prediction = b + ((a - cc) >> 1)
                            case 7: prediction = (a + b) >> 1
                            default: prediction = a
                            }
                        }
                        o[i] = UInt16(truncatingIfNeeded: prediction + difference(lookups[c]))
                    }
                }
            }
            return Array(o)
        }
    }
}
