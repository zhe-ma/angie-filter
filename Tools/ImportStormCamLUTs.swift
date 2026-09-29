// Converts StormCam's 11 standard and 16 Log looks into the app's LUT format.
// The source is the decrypted demo export from the StormCam 1.5.4 reverse, where each look is a
// 33³ or 65³ text .cube with red varying fastest. Both families output ordinary SDR.
//
// Standard looks take sRGB photos, which is also how LUTStore reads ours, so they are only resampled.
// Log looks take Apple Log (Rec.2020) footage. Our photo's white is already tone mapped down to 1, which
// these cubes render at about 0.85, so each lattice point is first expanded back to scene light, the same
// way as Tools/ImportHalideLUTs.swift: an inverse extended Reinhard on the max channel, display white to
// `sceneWhite`, 18% gray kept at 18%. Then Rec.2020, Apple Log, and the cube.
//
//   swiftc -O Tools/ImportStormCamLUTs.swift -o /tmp/import-stormcam
//   /tmp/import-stormcam /Users/zhe/Desktop/reverse/stormcam/reverse/decrypted/demo/luts
//
// Writes Resources/StormCamLUTs/storm-<id>.png as 512×512 PNGs:
// 8×8 tiles, blue 0 top-left, red across, green down.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Family { case standard, log }

/// Look id to the StormCam file name; the 65³ file where StormCam ships one.
/// Keep in sync with `stormLooks` in Tools/ImportFilmLUTs.swift.
let looks: [(id: String, source: String, family: Family)] = [
    ("losangeles", "洛杉矶33.cube", .standard),
    ("lapland", "拉普兰33.cube", .standard),
    ("bali", "巴厘岛33.cube", .standard),
    ("milan", "米兰33.cube", .standard),
    ("oslo", "奥斯陆33.cube", .standard),
    ("seville", "塞维利亚33.cube", .standard),
    ("reykjavik", "雷克雅维克33.cube", .standard),
    ("queensland", "昆士兰33.cube", .standard),
    ("prague", "布拉格33.cube", .standard),
    ("lasvegas", "拉斯维加斯33.cube", .standard),
    ("cannes", "戛纳33.cube", .standard),
    ("restore", "Rec709.cube", .log),
    ("natural", "Rec709Fix.cube", .log),
    ("seoul", "首尔33.cube", .log),
    ("island", "Fuji33.cube", .log),
    ("kamakura", "镰仓.cube", .log),
    ("manhattan", "曼哈顿33.cube", .log),
    ("tuscany", "托斯卡纳.cube", .log),
    ("shangrila", "香格里拉33.cube", .log),
    ("monochrome", "黑白.cube", .log),
    ("modern", "摩登.cube", .log),
    ("rome", "罗马33.cube", .log),
    ("gobi", "戈壁33.cube", .log),
    ("london", "伦敦33.cube", .log),
    ("istanbul", "伊斯坦布尔.cube", .log),
    ("sydney", "悉尼33.cube", .log),
    ("kiruna", "基律纳33.cube", .log),
]

/// Scene value display white expands to. The Log cubes reach 1 around 8 to 12.
let sceneWhite: Float = 12

struct ImportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func clamp01(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
}

struct Cube {
    let size: Int
    let data: [SIMD3<Float>]

    init(url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var size = 0
        var values: [SIMD3<Float>] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") { continue }
            if line.hasPrefix("DOMAIN_MIN") || line.hasPrefix("DOMAIN_MAX") {
                let bounds = line.split(separator: " ").dropFirst().compactMap { Float($0) }
                let expected: Float = line.hasPrefix("DOMAIN_MIN") ? 0 : 1
                guard bounds == [expected, expected, expected] else {
                    throw ImportError("定义域不是 0 到 1：\(url.lastPathComponent)")
                }
                continue
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(separator: " ").last ?? "") ?? 0
                values.reserveCapacity(size * size * size)
                continue
            }
            let parts = line.split(separator: " ").compactMap { Float($0) }
            if parts.count == 3 { values.append(SIMD3(parts[0], parts[1], parts[2])) }
        }
        guard size > 1, values.count == size * size * size else {
            throw ImportError("不是 3D LUT：\(url.lastPathComponent)")
        }
        self.size = size
        data = values
    }

    func sample(_ p: SIMD3<Float>) -> SIMD3<Float> {
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

// MARK: - Log input

func srgbDecode(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

/// Linear sRGB to linear Rec.2020, ITU-R BT.2087.
func rec2020(_ v: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3((SIMD3<Float>(0.627404, 0.329283, 0.043313) * v).sum(),
          (SIMD3<Float>(0.069097, 0.919540, 0.011362) * v).sum(),
          (SIMD3<Float>(0.016391, 0.088013, 0.895595) * v).sum())
}

/// Apple Log Profile White Paper, 2023.
func appleLog(_ r: Float) -> Float {
    let r0: Float = -0.05641088, rt: Float = 0.01, c: Float = 47.28711236
    let beta: Float = 0.00964052, gamma: Float = 0.08550479, delta: Float = 0.69336945
    if r >= rt { return gamma * log2(r + beta) + delta }
    if r >= r0 { return c * (r - r0) * (r - r0) }
    return 0
}

/// Solves m = s(1 + s/W²)/(1 + s) for s, so display 1 maps to W.
func expandedReinhard(_ m: Float) -> Float {
    let w2 = sceneWhite * sceneWhite
    let b = 1 - m
    return (-b + (b * b + 4 * m / w2).squareRoot()) * w2 / 2
}

let grayScale: Float = 0.18 / expandedReinhard(0.18)

func appleLogInput(_ srgb: SIMD3<Float>) -> SIMD3<Float> {
    let linear = SIMD3(srgbDecode(srgb.x), srgbDecode(srgb.y), srgbDecode(srgb.z))
    let m = linear.max()
    let scene = m > 0 ? linear * (expandedReinhard(min(m, 1)) * grayScale / m) : .zero
    let wide = rec2020(scene)
    return SIMD3(appleLog(wide.x), appleLog(wide.y), appleLog(wide.z))
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
    fputs("用法：import-stormcam <StormCam demo 的 luts 目录>\n", stderr)
    exit(2)
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = repository.appendingPathComponent("AngieFilter/Resources/StormCamLUTs", isDirectory: true)

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    var written = Set<String>()
    for look in looks {
        let cube = try Cube(url: sourceRoot.appendingPathComponent(look.source))
        let name = "storm-\(look.id).png"
        let pixels = switch look.family {
        case .standard: lutPixels { cube.sample($0) }
        case .log: lutPixels { cube.sample(appleLogInput($0)) }
        }
        try writePNG(pixels, to: outputDirectory.appendingPathComponent(name))
        written.insert(name)
    }
    for file in try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
    where file.hasSuffix(".png") && !written.contains(file) {
        try FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(file))
    }
    print("wrote \(written.count) StormCam LUTs to \(outputDirectory.path)")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
