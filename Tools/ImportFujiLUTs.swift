// Turns Fujifilm's F-Log2 film-simulation 3D LUTs into the app's LUT format, one camera per
// series on https://www.fujifilm-x.com/global/support/download/lut/.
// The source LUTs expect F-Log2 footage, not a finished photo. Each output is
// FLog2_to_<SIM> ∘ inverse(FLog2_to_WDR): the photo is taken as that camera's neutral WDR render,
// mapped back to the F-Log2 that would produce it, then rendered with the simulation.
//
// Fujifilm publishes these LUTs without a redistribution license. The generated PNGs are for
// local builds only; do not ship them in a public release without Fujifilm's permission.
//
//   mkdir -p /tmp/fuji-lut && cd /tmp/fuji-lut
//   curl -LO https://dl.fujifilm-x.com/support/lut/gfx-eterna-55-3d-lut-v110.zip   # eterna55
//   curl -LO https://dl.fujifilm-x.com/lut/gfx100II-3d-lut-v100.zip                # gfx100ii
//   curl -LO https://dl.fujifilm-x.com/lut/gfx100rf-3d-lut-v100.zip                # gfx100rf
//   curl -LO https://dl.fujifilm-x.com/lut/x-t30iii-3d-lut-v100.zip                # xt30iii
//   curl -LO https://dl.fujifilm-x.com/lut/x100vi-3d-lut-v100.zip                  # x100vi
//   unzip each archive into a folder named by its package id, e.g. unzip gfx100II-3d-lut-v100.zip -d gfx100ii
//   swiftc -O Tools/ImportFujiLUTs.swift -o /tmp/import-fuji
//   /tmp/import-fuji /tmp/fuji-lut
//
// Writes Resources/FujiLUTs/fuji-<package>-<sim>.png as 512×512 PNGs:
// 8×8 tiles, blue 0 top-left, red across, green down.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Simulation id to the name Fujifilm uses after `_to_` in the .cube file name.
let simulationSources: [String: String] = [
    "provia": "PROVIA",
    "velvia": "Velvia",
    "astia": "ASTIA",
    "classicchrome": "CLASSIC-CHROME",
    "realaace": "REALA-ACE",
    "proneg": "PRO-Neg.Std",
    "classicneg": "CLASSIC-Neg.",
    "eterna": "ETERNA",
    "eternabb": "ETERNA-BB",
    "acros": "ACROS",
]

struct Package {
    let id: String
    let simulations: [String]
}

/// Keep in sync with `fujiPackages` in Tools/ImportFilmLUTs.swift.
let packages: [Package] = [
    Package(id: "eterna55", simulations: ["provia", "velvia", "astia", "classicchrome", "realaace", "proneg", "classicneg", "eterna", "eternabb", "acros"]),
    Package(id: "gfx100ii", simulations: ["eterna", "eternabb"]),
    Package(id: "gfx100rf", simulations: ["eterna", "eternabb"]),
    Package(id: "xt30iii", simulations: ["eterna", "eternabb"]),
    Package(id: "x100vi", simulations: ["eterna", "eternabb"]),
]

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
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("TITLE") || line.hasPrefix("DOMAIN") { continue }
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

    /// Red varies fastest, as in the .cube format.
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

/// Finds x with wdr(x) ≈ target. The WDR curve is flat near black and white, so plain Newton stalls there.
/// It seeds from the nearest forward sample on the cube's own lattice and keeps only steps that lower the error.
/// Very saturated sRGB blues are outside what WDR renders; those land on the closest color it can make.
struct WDRInverse {
    static let buckets = 24
    let wdr: Cube
    var grid: [[Int32]]

    init(wdr: Cube) {
        self.wdr = wdr
        let n = Self.buckets
        grid = Array(repeating: [], count: n * n * n)
        for (index, out) in wdr.data.enumerated() {
            grid[Self.bucket(out)].append(Int32(index))
        }
    }

    static func cell(_ v: Float) -> Int { min(max(Int(v * Float(buckets)), 0), buckets - 1) }
    static func bucket(_ v: SIMD3<Float>) -> Int { cell(v.x) + cell(v.y) * buckets + cell(v.z) * buckets * buckets }

    func seed(_ target: SIMD3<Float>) -> SIMD3<Float> {
        let n = Self.buckets
        let cx = Self.cell(target.x), cy = Self.cell(target.y), cz = Self.cell(target.z)
        var best = (distance: Float.infinity, index: 0)
        for radius in 0..<n {
            for z in max(cz - radius, 0)...min(cz + radius, n - 1) {
                for y in max(cy - radius, 0)...min(cy + radius, n - 1) {
                    for x in max(cx - radius, 0)...min(cx + radius, n - 1)
                    where max(abs(x - cx), abs(y - cy), abs(z - cz)) == radius {
                        for index in grid[x + y * n + z * n * n] {
                            let d = wdr.data[Int(index)] - target
                            let distance = (d * d).sum()
                            if distance < best.distance { best = (distance, Int(index)) }
                        }
                    }
                }
            }
            if best.distance.isFinite, radius >= 1 { break }
        }
        let s = wdr.size
        return SIMD3(Float(best.index % s), Float((best.index / s) % s), Float(best.index / (s * s))) / Float(s - 1)
    }

    func solve(_ target: SIMD3<Float>) -> SIMD3<Float> {
        var x = seed(target)
        let h: Float = 1e-3
        func cost(_ p: SIMD3<Float>) -> Float { let e = wdr.sample(p) - target; return (e * e).sum() }
        func det(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
            a.x * (b.y * c.z - c.y * b.z) - b.x * (a.y * c.z - c.y * a.z) + c.x * (a.y * b.z - b.y * a.z)
        }
        for _ in 0..<32 {
            let f = wdr.sample(x) - target
            if max(abs(f.x), abs(f.y), abs(f.z)) < 1e-5 { break }
            let jx = (wdr.sample(x + SIMD3(h, 0, 0)) - wdr.sample(x - SIMD3(h, 0, 0))) / (2 * h)
            let jy = (wdr.sample(x + SIMD3(0, h, 0)) - wdr.sample(x - SIMD3(0, h, 0))) / (2 * h)
            let jz = (wdr.sample(x + SIMD3(0, 0, h)) - wdr.sample(x - SIMD3(0, 0, h))) / (2 * h)
            let d = det(jx, jy, jz)
            guard abs(d) > 1e-9 else { break }
            let step = SIMD3(det(f, jy, jz), det(jx, f, jz), det(jx, jy, f)) / d
            let current = (f * f).sum()
            var scale: Float = 1
            var moved = false
            for _ in 0..<12 {
                let candidate = clamp01(x - step * scale)
                if cost(candidate) < current {
                    x = candidate
                    moved = true
                    break
                }
                scale *= 0.5
            }
            if !moved { break }
        }
        return x
    }
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
    fputs("用法：import-fuji <解压后的富士 3D-LUT 目录>\n", stderr)
    exit(2)
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputDirectory = repository.appendingPathComponent("AngieFilter/Resources/FujiLUTs", isDirectory: true)

/// Names differ by camera: `FLog2_to_ETERNA_65grid_V.1.00.cube`, `X100VI_FLog2_FGamut_to_ETERNA_BT.709_33grid_V.1.00.cube`.
/// Only F-Log2 counts, not F-Log or F-Log2 C. The neutral render is `WDR` or `WDR-709`. The 65 grid wins over 33.
func cubeURL(in folder: URL, simulation: String) throws -> URL {
    let wanted = simulation == "WDR" ? ["WDR", "WDR-709"] : [simulation]
    var best: (grid: Int, url: URL)?
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
    while let url = enumerator?.nextObject() as? URL {
        guard url.pathExtension == "cube" else { continue }
        let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: "_to_")
        guard parts.count == 2 else { continue }
        let log = parts[0].components(separatedBy: "_")
        guard log.contains("FLog2") else { continue }
        let target = parts[1].components(separatedBy: "_")
        guard let name = target.first, wanted.contains(name) else { continue }
        let grid = target.contains("65grid") ? 65 : 33
        if best == nil || grid > best!.grid { best = (grid, url) }
    }
    guard let best else { throw ImportError("\(folder.lastPathComponent) 里找不到 F-Log2 到 \(simulation) 的 LUT") }
    return best.url
}

func inverseLattice(for wdr: Cube) -> [SIMD3<Float>] {
    let inverter = WDRInverse(wdr: wdr)
    var inverse = [SIMD3<Float>](repeating: .zero, count: lattice * lattice * lattice)
    inverse.withUnsafeMutableBufferPointer { buffer in
        let base = buffer.baseAddress!
        DispatchQueue.concurrentPerform(iterations: lattice) { blue in
            for green in 0..<lattice {
                for red in 0..<lattice {
                    let target = SIMD3<Float>(Float(red), Float(green), Float(blue)) / Float(lattice - 1)
                    base[red + green * lattice + blue * lattice * lattice] = inverter.solve(target)
                }
            }
        }
    }
    return inverse
}

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let top = Float(lattice - 1)
    var written = Set<String>()
    for package in packages {
        let folder = sourceRoot.appendingPathComponent(package.id, isDirectory: true)
        let inverse = inverseLattice(for: try Cube(url: cubeURL(in: folder, simulation: "WDR")))
        func logValue(for input: SIMD3<Float>) -> SIMD3<Float> {
            let i = SIMD3<Int>(Int((input.x * top).rounded()), Int((input.y * top).rounded()), Int((input.z * top).rounded()))
            return inverse[i.x + i.y * lattice + i.z * lattice * lattice]
        }
        for simulation in package.simulations {
            guard let source = simulationSources[simulation] else { throw ImportError("未知的模拟 \(simulation)") }
            let cube = try Cube(url: cubeURL(in: folder, simulation: source))
            let name = "fuji-\(package.id)-\(simulation).png"
            try writePNG(lutPixels { cube.sample(logValue(for: $0)) }, to: outputDirectory.appendingPathComponent(name))
            written.insert(name)
        }
    }
    for file in try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
    where file.hasSuffix(".png") && !written.contains(file) {
        try FileManager.default.removeItem(at: outputDirectory.appendingPathComponent(file))
    }
    print("wrote \(written.count) Fujifilm LUTs to \(outputDirectory.path)")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
