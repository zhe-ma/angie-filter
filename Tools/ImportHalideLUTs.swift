// Bakes Halide 3.1.x's six creative-look grades into the app's LUT format.
// Each .ccube is a raw LZFSE stream of a 33³ RGB Float16 cube, red fastest. Halide feeds it scene-linear
// ProRAW encoded as Apple Log (Rec.2020) or Apple Log 2 (Apple Wide Gamut), and decodes the result as
// Display P3 gamma 2.2, or for Chroma Noir as Rec.2020 PQ.
//
// Our input is a finished sRGB photo, whose white is already tone mapped down to 1. Fed straight in, it
// lands on scene 1.0, which Halide renders at about 0.8. So each lattice point is first expanded back to
// scene light: an inverse extended Reinhard on the max channel, with display white going to `sceneWhite`
// and 18% gray kept at 18%. Then gamut, Apple Log, the cube, the output decode, and back to sRGB.
//
//   mkdir -p /tmp/halide && unzip -q <Halide .ipa> '*.ccube' -d /tmp/halide/ipa
//   swiftc -O Tools/ImportHalideLUTs.swift -o /tmp/import-halide
//   /tmp/import-halide /tmp/halide/ipa/Payload/Halide.app/Frameworks/HalideCamera.framework
//
// Writes Resources/HalideLUTs/halide-<id>.png as 512×512 PNGs:
// 8×8 tiles, blue 0 top-left, red across, green down.

import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Input { case appleLog, appleLog2 }
enum Output { case p3Gamma22, rec2020PQ }

/// SDR connections from the Halide 3.1.2 report §6.5. Keep in sync with the `halide` family in LookLibrary.
let looks: [(id: String, file: String, input: Input, output: Output)] = [
    ("valencia", "ValenciaDisplayP3SDR.ccube", .appleLog2, .p3Gamma22),
    ("rembrandt", "RembrandtSDR.ccube", .appleLog2, .p3Gamma22),
    ("nova", "NovaSDR.ccube", .appleLog2, .p3Gamma22),
    ("zephyr", "ZephyrDisplayP3SDR.ccube", .appleLog2, .p3Gamma22),
    ("scarlet", "ScarletSDR.ccube", .appleLog2, .p3Gamma22),
    ("chromanoir", "ChromaNoirSceneSDR.ccube", .appleLog, .rec2020PQ),
]

/// Scene value display white expands to. Halide's grades reach 0.99 around 8 to 10.
let sceneWhite: Float = 12
/// Chroma Noir's PQ output levels off at 100 nits, taken as display white.
let pqWhiteNits: Float = 100

struct ImportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func clamp01(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
}

// MARK: - Color

struct Matrix3 {
    var rows: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    static func * (m: Matrix3, v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((m.rows.0 * v).sum(), (m.rows.1 * v).sum(), (m.rows.2 * v).sum())
    }

    static func * (a: Matrix3, b: Matrix3) -> Matrix3 {
        let columns = (SIMD3(b.rows.0.x, b.rows.1.x, b.rows.2.x),
                       SIMD3(b.rows.0.y, b.rows.1.y, b.rows.2.y),
                       SIMD3(b.rows.0.z, b.rows.1.z, b.rows.2.z))
        func row(_ r: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3((r * columns.0).sum(), (r * columns.1).sum(), (r * columns.2).sum())
        }
        return Matrix3(rows: (row(a.rows.0), row(a.rows.1), row(a.rows.2)))
    }

    var inverse: Matrix3 {
        let (a, b, c) = rows
        let x = SIMD3(b.y * c.z - b.z * c.y, a.z * c.y - a.y * c.z, a.y * b.z - a.z * b.y)
        let y = SIMD3(b.z * c.x - b.x * c.z, a.x * c.z - a.z * c.x, a.z * b.x - a.x * b.z)
        let z = SIMD3(b.x * c.y - b.y * c.x, a.y * c.x - a.x * c.y, a.x * b.y - a.y * b.x)
        let det = a.x * x.x + a.y * y.x + a.z * z.x
        return Matrix3(rows: (x / det, y / det, z / det))
    }
}

/// RGB to XYZ from xy primaries, all on D65, so no chromatic adaptation is needed.
func rgbToXYZ(_ r: (Float, Float), _ g: (Float, Float), _ b: (Float, Float)) -> Matrix3 {
    func xyz(_ p: (Float, Float)) -> SIMD3<Float> { SIMD3(p.0 / p.1, 1, (1 - p.0 - p.1) / p.1) }
    let white = xyz((0.3127, 0.3290))
    let (xr, xg, xb) = (xyz(r), xyz(g), xyz(b))
    let primaries = Matrix3(rows: (SIMD3(xr.x, xg.x, xb.x), SIMD3(xr.y, xg.y, xb.y), SIMD3(xr.z, xg.z, xb.z)))
    let s = primaries.inverse * white
    return Matrix3(rows: (primaries.rows.0 * s, primaries.rows.1 * s, primaries.rows.2 * s))
}

let srgbToXYZ = rgbToXYZ((0.64, 0.33), (0.30, 0.60), (0.15, 0.06))
let p3ToXYZ = rgbToXYZ((0.680, 0.320), (0.265, 0.690), (0.150, 0.060))
let rec2020ToXYZ = rgbToXYZ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046))
/// Apple Wide Gamut, as in the OpenColorIO ACES config's Apple Log 2.
let appleWideGamutToXYZ = rgbToXYZ((0.725, 0.301), (0.221, 0.814), (0.068, -0.076))

func srgbDecode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
func srgbEncode(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

/// Apple Log Profile White Paper, 2023. Apple Log 2 uses the same curve.
func appleLog(_ r: Float) -> Float {
    let r0: Float = -0.05641088, rt: Float = 0.01, c: Float = 47.28711236
    let beta: Float = 0.00964052, gamma: Float = 0.08550479, delta: Float = 0.69336945
    if r >= rt { return gamma * log2(r + beta) + delta }
    if r >= r0 { return c * (r - r0) * (r - r0) }
    return 0
}

/// SMPTE ST 2084, in nits.
func pqNits(_ e: Float) -> Float {
    let m1: Float = 2610 / 16384, m2: Float = 2523 / 4096 * 128
    let c1: Float = 3424 / 4096, c2: Float = 2413 / 4096 * 32, c3: Float = 2392 / 4096 * 32
    let p = pow(max(e, 0), 1 / m2)
    return pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1) * 10000
}

/// Solves m = s(1 + s/W²)/(1 + s) for s, so display 1 maps to W.
func expandedReinhard(_ m: Float) -> Float {
    let w2 = sceneWhite * sceneWhite
    let b = 1 - m
    return (-b + (b * b + 4 * m / w2).squareRoot()) * w2 / 2
}

let grayScale: Float = 0.18 / expandedReinhard(0.18)

func sceneLight(_ display: SIMD3<Float>) -> SIMD3<Float> {
    let m = display.max()
    guard m > 0 else { return .zero }
    return display * (expandedReinhard(min(m, 1)) * grayScale / m)
}

// MARK: - Cube

struct Cube {
    static let size = 33
    let data: [SIMD3<Float>]

    init(url: URL) throws {
        let encoded = try Data(contentsOf: url)
        let count = Self.size * Self.size * Self.size
        var decoded = [UInt8](repeating: 0, count: count * 3 * 2)
        let written = encoded.withUnsafeBytes { source in
            compression_decode_buffer(&decoded, decoded.count,
                                      source.bindMemory(to: UInt8.self).baseAddress!, encoded.count,
                                      nil, COMPRESSION_LZFSE)
        }
        guard written == decoded.count else {
            throw ImportError("解压后大小不对：\(url.lastPathComponent) \(written)")
        }
        let halves = decoded.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        data = (0..<count).map { SIMD3(Float(halves[$0 * 3]), Float(halves[$0 * 3 + 1]), Float(halves[$0 * 3 + 2])) }
    }

    func sample(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let size = Self.size
        let q = clamp01(p) * Float(size - 1)
        let i = SIMD3<Int>(min(Int(q.x), size - 2), min(Int(q.y), size - 2), min(Int(q.z), size - 2))
        let t = q - SIMD3<Float>(Float(i.x), Float(i.y), Float(i.z))
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            data[(i.x + r) + (i.y + g) * size + (i.z + b) * size * size]
        }
        let c00 = at(0, 0, 0) + (at(1, 0, 0) - at(0, 0, 0)) * t.x
        let c10 = at(0, 1, 0) + (at(1, 1, 0) - at(0, 1, 0)) * t.x
        let c01 = at(0, 0, 1) + (at(1, 0, 1) - at(0, 0, 1)) * t.x
        let c11 = at(0, 1, 1) + (at(1, 1, 1) - at(0, 1, 1)) * t.x
        let c0 = c00 + (c10 - c00) * t.y
        let c1 = c01 + (c11 - c01) * t.y
        return c0 + (c1 - c0) * t.z
    }
}

func render(_ srgb: SIMD3<Float>, cube: Cube, input: Input, output: Output) -> SIMD3<Float> {
    let linear = SIMD3(srgbDecode(srgb.x), srgbDecode(srgb.y), srgbDecode(srgb.z))
    let scene = sceneLight(linear)
    let toInput = (input == .appleLog ? rec2020ToXYZ : appleWideGamutToXYZ).inverse * srgbToXYZ
    let log = toInput * scene
    let graded = cube.sample(SIMD3(appleLog(log.x), appleLog(log.y), appleLog(log.z)))
    let outLinear: SIMD3<Float>
    switch output {
    case .p3Gamma22:
        let p3 = SIMD3(pow(max(graded.x, 0), 2.2), pow(max(graded.y, 0), 2.2), pow(max(graded.z, 0), 2.2))
        outLinear = srgbToXYZ.inverse * p3ToXYZ * p3
    case .rec2020PQ:
        let rec2020 = SIMD3(pqNits(graded.x), pqNits(graded.y), pqNits(graded.z)) / pqWhiteNits
        outLinear = srgbToXYZ.inverse * rec2020ToXYZ * rec2020
    }
    let clipped = clamp01(outLinear)
    return SIMD3(srgbEncode(clipped.x), srgbEncode(clipped.y), srgbEncode(clipped.z))
}

// MARK: - 512 LUT PNG

let lattice = 64
let tileSide = 512

func lutPixels(_ lookup: (SIMD3<Float>) -> SIMD3<Float>) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: tileSide * tileSide * 4)
    let top = Float(lattice - 1)
    for blue in 0..<lattice {
        let originX = (blue % 8) * lattice
        let originY = (blue / 8) * lattice
        for green in 0..<lattice {
            for red in 0..<lattice {
                let value = clamp01(lookup(SIMD3(Float(red), Float(green), Float(blue)) / top))
                let index = ((originY + green) * tileSide + originX + red) * 4
                pixels[index] = UInt8((value.x * 255).rounded())
                pixels[index + 1] = UInt8((value.y * 255).rounded())
                pixels[index + 2] = UInt8((value.z * 255).rounded())
            }
        }
    }
    return pixels
}

func writePNG(_ pixels: [UInt8], to url: URL) throws {
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let image = CGImage(
              width: tileSide,
              height: tileSide,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: tileSide * 4,
              space: space,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw ImportError("无法编码 \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ImportError("写入失败 \(url.path)")
    }
}

// MARK: - Main

guard let sourceRoot = CommandLine.arguments.dropFirst().first.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
    fputs("用法：import-halide <Halide.app/Frameworks/HalideCamera.framework>\n", stderr)
    exit(2)
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = repository.appendingPathComponent("AngieFilter/Resources/HalideLUTs", isDirectory: true)

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var written = Set<String>()
    for look in looks {
        let cube = try Cube(url: sourceRoot.appendingPathComponent(look.file))
        let name = "halide-\(look.id).png"
        try writePNG(lutPixels { render($0, cube: cube, input: look.input, output: look.output) },
                     to: outputDirectory.appendingPathComponent(name))
        written.insert(name)
    }
    for file in try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
    where file.hasSuffix(".png") && !written.contains(file) {
        try FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(file))
    }
    print("wrote \(written.count) Halide LUTs to \(outputDirectory.path)")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
