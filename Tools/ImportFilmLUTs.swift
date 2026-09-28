// Converts the RawTherapee Film Simulation Collection (CC BY-SA 4.0) into the app's LUT format
// and writes Looks.json.
//
//   git clone https://github.com/cedeber/hald-clut.git /tmp/hald-clut
//   swiftc -O Tools/ImportFilmLUTs.swift -o /tmp/import-luts
//   /tmp/import-luts /tmp/hald-clut/HaldCLUT
//
// `--sources` prints the HaldCLUT paths this catalog reads, for a sparse checkout.
// Each HaldCLUT is level 12 (a 144³ table in a 1728×1728 sRGB PNG). It is resampled to 64³
// and written as a 512×512 PNG: 8×8 tiles, blue 0 top-left, red across, green down.
// The grain plates are rewritten from fixed seeds so they stay identical between runs.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Film {
    let id: String
    let name: String
    let about: String
    let source: String
    var strength: Float = 1
    var grain: Float = 0
    var plate = "fine"
    var vignette: Float = 0
    var halation: Float = 0
}

struct BuiltIn {
    let id: String
    let name: String
    let about: String
    let filter: String
}

/// Fujifilm digital film simulations. Their PNGs come from Tools/ImportFujiLUTs.swift.
struct FujiSimulation {
    let id: String
    let name: String
    let about: String
    var strength: Float = 1
}

/// One camera per series on Fujifilm's LUT download page.
struct FujiPackage {
    let id: String
    let model: String
    let simulations: [String]
}

let color = "Film Simulation/Color"
let mono = "Film Simulation/Black and White"

let films: [Film] = [
    // Kodak
    Film(id: "portra160", name: "波特拉 160", about: "低感人像负片。反差低，肤色暖而干净。",
         source: "\(color)/Kodak/Kodak Portra 160 2.png", grain: 0.12),
    Film(id: "portra400", name: "波特拉 400", about: "最常用的人像负片。肤色柔和，高光宽容。",
         source: "\(color)/Kodak/Kodak Portra 400 2.png", grain: 0.18),
    Film(id: "portra400vc", name: "波特拉 VC", about: "Portra 400 的鲜艳版，饱和和反差都高一些。",
         source: "\(color)/Kodak/Kodak Portra 400 VC 2.png", grain: 0.18),
    Film(id: "portra800", name: "波特拉 800", about: "高感人像负片。偏暖，颗粒更明显。",
         source: "\(color)/Kodak/Kodak Portra 800 2.png", grain: 0.26, plate: "coarse"),
    Film(id: "ektar100", name: "艾克塔 100", about: "风景负片。色彩浓，颗粒极细。",
         source: "\(color)/Kodak/Kodak Ektar 100.png", grain: 0.08),
    Film(id: "elite200", name: "精英 200", about: "柯达日常负片。偏暖，街拍和旅行。",
         source: "\(color)/Kodak/Kodak Elite Color 200.png", grain: 0.2),
    Film(id: "elite400", name: "精英 400", about: "更高感光的日常负片，暖调更明显。",
         source: "\(color)/Kodak/Kodak Elite Color 400.png", strength: 0.85, grain: 0.24),
    Film(id: "kodachrome64", name: "柯达克罗姆", about: "经典反转片。红黄浓郁，阴影深。",
         source: "\(color)/Kodak/Kodak Kodachrome 64.png", strength: 0.85, grain: 0.1, vignette: 0.15),
    Film(id: "ektachrome100vs", name: "爱克塔克罗姆", about: "高饱和反转片。蓝天和绿叶很鲜。",
         source: "\(color)/Kodak/Kodak Ektachrome 100 VS.png", strength: 0.85, grain: 0.08),
    Film(id: "elitechrome200", name: "精英反转", about: "柯达日常反转片，色彩明快。",
         source: "\(color)/Kodak/Kodak Elite Chrome 200.png", grain: 0.12),
    Film(id: "trix400", name: "Tri-X 400", about: "经典黑白。反差硬，颗粒粗。",
         source: "\(mono)/Kodak/Kodak TRI-X 400 2.png", grain: 0.34, plate: "coarse"),
    Film(id: "tmax100", name: "T-Max 100", about: "细颗粒黑白，影调平滑。",
         source: "\(mono)/Kodak/Kodak T-Max 100.png", grain: 0.1),
    Film(id: "bw400cn", name: "BW400CN", about: "按彩色流程冲洗的黑白，影调偏柔。",
         source: "\(mono)/Kodak/Kodak BW 400 CN.png", grain: 0.16),

    // Fuji
    Film(id: "pro400h", name: "Pro 400H", about: "婚礼人像负片。偏青绿，高光通透。",
         source: "\(color)/Fuji/Fuji 400H 2.png", grain: 0.18),
    Film(id: "pro160c", name: "Pro 160C", about: "低感专业负片。干净，略偏冷。",
         source: "\(color)/Fuji/Fuji 160C 2.png", grain: 0.1),
    Film(id: "pro800z", name: "Pro 800Z", about: "高感人像负片。肤色自然，颗粒明显。",
         source: "\(color)/Fuji/Fuji 800Z 2.png", grain: 0.26, plate: "coarse"),
    Film(id: "superia200", name: "Superia 200", about: "富士日常负片。绿色偏重。",
         source: "\(color)/Fuji/Fuji Superia 200.png", grain: 0.18),
    Film(id: "superia400", name: "Superia 400", about: "日常负片。阴影偏青，绿叶浓。",
         source: "\(color)/Fuji/Fuji Superia 400 2.png", strength: 0.85, grain: 0.22),
    Film(id: "superia800", name: "Superia 800", about: "高感日常负片。颗粒粗，色彩更重。",
         source: "\(color)/Fuji/Fuji Superia X-Tra 800.png", strength: 0.85, grain: 0.28, plate: "coarse"),
    Film(id: "reala100", name: "Reala 100", about: "还原准确的负片，色彩克制。",
         source: "\(color)/Fuji/Fuji Superia Reala 100.png", grain: 0.1),
    Film(id: "velvia50", name: "Velvia 50", about: "风光反转片。饱和极高，反差大。",
         source: "\(color)/Fuji/Fuji Velvia 50.png", strength: 0.85, grain: 0.06),
    Film(id: "provia100f", name: "Provia 100F", about: "标准反转片。中性，通透。",
         source: "\(color)/Fuji/Fuji Provia 100F.png", grain: 0.06),
    Film(id: "astia100f", name: "Astia 100F", about: "柔和反转片，适合人像。",
         source: "\(color)/Fuji/Fuji Astia 100F.png", grain: 0.06),
    Film(id: "acros100", name: "Acros 100", about: "细腻黑白，中间调丰富。",
         source: "\(mono)/Fuji/Fuji Neopan Acros 100.png", grain: 0.1),
    Film(id: "neopan1600", name: "Neopan 1600", about: "高感黑白。反差硬，颗粒粗。",
         source: "\(mono)/Fuji/Fuji Neopan 1600 2.png", grain: 0.4, plate: "coarse"),

    // Instant
    Film(id: "fp100c", name: "FP-100C", about: "富士撕拉片。偏青，反差柔。",
         source: "\(color)/Fuji/Fuji FP-100c 3.png", grain: 0.16, vignette: 0.3),
    Film(id: "polaroid669", name: "宝丽来 669", about: "老式撕拉片。偏暖，带点褪色。",
         source: "\(color)/Polaroid/Polaroid 669 3.png", grain: 0.18, vignette: 0.3),
    Film(id: "polaroid669cold", name: "669 冷调", about: "669 的冷调冲法，阴影偏蓝。",
         source: "\(color)/Polaroid/Polaroid 669 Cold 3.png", grain: 0.18, vignette: 0.3),
    Film(id: "polaroid690", name: "宝丽来 690", about: "撕拉片。色彩比 669 更饱和。",
         source: "\(color)/Polaroid/Polaroid 690 3.png", strength: 0.85, grain: 0.18, vignette: 0.3),
    Film(id: "px70", name: "PX-70", about: "SX-70 相纸。淡，偏粉，暗部发闷。",
         source: "\(color)/Polaroid/Polaroid PX-70 3.png", strength: 0.85, grain: 0.2, vignette: 0.4),
    Film(id: "px680", name: "PX-680", about: "600 相纸。暖黄，反差低。",
         source: "\(color)/Polaroid/Polaroid PX-680 3.png", grain: 0.2, vignette: 0.35),
    Film(id: "px100warm", name: "PX-100 暖", about: "黑白相纸的暖调版，带一点棕。",
         source: "\(color)/Polaroid/Polaroid PX-100UV+ Warm 3.png", grain: 0.2, vignette: 0.35),
    Film(id: "timezero", name: "过期相纸", about: "过期的 Time Zero。偏色明显，像放了很多年。",
         source: "\(color)/Polaroid/Polaroid Time Zero (Expired) 4.png", strength: 0.6, grain: 0.22, vignette: 0.4),
    Film(id: "polachrome", name: "Polachrome", about: "宝丽来反转片。发闷，偏品红。",
         source: "\(color)/Polaroid/Polaroid Polachrome.png", grain: 0.18),
    Film(id: "polaroid665", name: "宝丽来 665", about: "黑白撕拉片。灰阶长，暗部柔。",
         source: "\(mono)/Polaroid/Polaroid 665 3.png", grain: 0.18, vignette: 0.3),

    // Black and white
    Film(id: "hp5", name: "HP5 400", about: "依尔福经典黑白。宽容度大，颗粒明显。",
         source: "\(mono)/Ilford/Ilford HP5 Plus 400.png", grain: 0.3, plate: "coarse"),
    Film(id: "delta100", name: "Delta 100", about: "依尔福细颗粒黑白，锐利。",
         source: "\(mono)/Ilford/Ilford Delta 100.png", grain: 0.1),
    Film(id: "delta3200", name: "Delta 3200", about: "超高感黑白。暗部重，颗粒很粗。",
         source: "\(mono)/Ilford/Ilford Delta 3200 2.png", grain: 0.45, plate: "coarse"),
    Film(id: "fp4", name: "FP4 125", about: "依尔福中感黑白，灰阶细。",
         source: "\(mono)/Ilford/Ilford FP4 Plus 125.png", grain: 0.14),
    Film(id: "panf50", name: "Pan F 50", about: "低感黑白。反差高，几乎没有颗粒。",
         source: "\(mono)/Ilford/Ilford Pan F Plus 50.png", grain: 0.05),
    Film(id: "xp2", name: "XP2", about: "按彩色流程冲洗的黑白，柔和。",
         source: "\(mono)/Ilford/Ilford XP2.png", grain: 0.14),
    Film(id: "apx100", name: "APX 100", about: "爱克发黑白。中性，略硬。",
         source: "\(mono)/Agfa/Agfa APX 100.png", grain: 0.12),
    Film(id: "retro100", name: "Retro 100", about: "禄来黑白。影调复古，高光柔。",
         source: "\(mono)/Rollei/Rollei Retro 100 Tonal.png", grain: 0.14),
    Film(id: "ortho25", name: "Ortho 25", about: "正色片。红色变暗，天空变亮。",
         source: "\(mono)/Rollei/Rollei Ortho 25.png", grain: 0.06),
    Film(id: "infrared", name: "红外", about: "柯达红外黑白。绿叶发白，天空发黑。",
         source: "\(mono)/Kodak/Kodak HIE (HS Infra).png", grain: 0.3, plate: "coarse"),

    // Agfa and cross-processing
    Film(id: "vista200", name: "Vista 200", about: "爱克发日常负片。偏暖，红色突出。",
         source: "\(color)/Agfa/Agfa Vista 200.png", grain: 0.2),
    Film(id: "precisa100", name: "Precisa 100", about: "爱克发反转片。偏冷，青色干净。",
         source: "\(color)/Agfa/Agfa Precisa 100.png", grain: 0.08),
    Film(id: "ultra100", name: "Ultra 100", about: "爱克发高饱和负片。",
         source: "\(color)/Agfa/Agfa Ultra Color 100.png", strength: 0.85, grain: 0.1),
    Film(id: "xproslide", name: "交叉冲洗", about: "反转片按负片冲洗。反差高，偏黄绿。",
         source: "\(color)/Lomography/Lomography X-Pro Slide 200.png", strength: 0.85, grain: 0.2, vignette: 0.3),
    Film(id: "redscale", name: "红阶", about: "反装胶片，整张偏红橙。",
         source: "\(color)/Lomography/Lomography Redscale 100.png", strength: 0.85, grain: 0.2, vignette: 0.3),
    Film(id: "elitexpro", name: "精英交叉", about: "柯达反转片交叉冲洗。偏青，高光发黄。",
         source: "\(color)/Kodak/Kodak Elite 100 XPRO.png", strength: 0.7, grain: 0.16),

    // Creative
    Film(id: "tealorange", name: "大片", about: "青橙对比。暗部偏青，肤色偏橙。",
         source: "\(color)/CreativePack-1/TealOrange.png", halation: 0.15),
    Film(id: "bleachbypass", name: "跳漂白", about: "低饱和、高反差的电影冲洗。",
         source: "\(color)/CreativePack-1/BleachBypass1.png", strength: 0.8, grain: 0.12),
    Film(id: "crispwarm", name: "暖阳", about: "通透的暖调。",
         source: "\(color)/CreativePack-1/CrispWarm.png"),
    Film(id: "crispwinter", name: "冬日", about: "通透的冷调。",
         source: "\(color)/CreativePack-1/CrispWinter.png"),
    Film(id: "softwarming", name: "柔暖", about: "轻微的暖调，不改反差。",
         source: "\(color)/CreativePack-1/SoftWarming.png"),
    Film(id: "latesunset", name: "日落", about: "像傍晚的橙色光。",
         source: "\(color)/CreativePack-1/LateSunset.png", strength: 0.6),
    Film(id: "fallcolors", name: "秋色", about: "黄橙加重，绿色压低。",
         source: "\(color)/CreativePack-1/FallColors.png"),
    Film(id: "moonlight", name: "月光", about: "冷蓝、偏暗。",
         source: "\(color)/CreativePack-1/Moonlight.png", strength: 0.7),
    Film(id: "foggynight", name: "雾夜", about: "低反差的夜色，发灰偏青。",
         source: "\(color)/CreativePack-1/FoggyNight.png", strength: 0.7, halation: 0.2),
    Film(id: "candlelight", name: "烛光", about: "暖黄的室内光。",
         source: "\(color)/CreativePack-1/CandleLight.png", strength: 0.75, halation: 0.15),
    Film(id: "tealmagentagold", name: "霓虹", about: "青、品红和金色三色分离。",
         source: "\(color)/CreativePack-1/TealMagentaGold.png", strength: 0.8),
]

let builtIns: [BuiltIn] = [
    BuiltIn(id: "sys-chrome", name: "铬黄", about: "Core Image 内置。饱和和反差略高，偏冷。", filter: "CIPhotoEffectChrome"),
    BuiltIn(id: "sys-fade", name: "褪色", about: "Core Image 内置。饱和降低，黑位抬起。", filter: "CIPhotoEffectFade"),
    BuiltIn(id: "sys-instant", name: "怀旧", about: "Core Image 内置。偏黄的旧照片。", filter: "CIPhotoEffectInstant"),
    BuiltIn(id: "sys-process", name: "冲印", about: "Core Image 内置。偏青的冲印色。", filter: "CIPhotoEffectProcess"),
    BuiltIn(id: "sys-transfer", name: "岁月", about: "Core Image 内置。暖而淡。", filter: "CIPhotoEffectTransfer"),
    BuiltIn(id: "sys-mono", name: "单色", about: "Core Image 内置。低反差黑白。", filter: "CIPhotoEffectMono"),
    BuiltIn(id: "sys-tonal", name: "色调", about: "Core Image 内置。灰阶均匀的黑白。", filter: "CIPhotoEffectTonal"),
    BuiltIn(id: "sys-noir", name: "黑白", about: "Core Image 内置。高反差黑白。", filter: "CIPhotoEffectNoir"),
]

let fujiSimulations: [String: FujiSimulation] = Dictionary(uniqueKeysWithValues: [
    FujiSimulation(id: "provia", name: "PROVIA", about: "富士标准。中性，通透。"),
    FujiSimulation(id: "velvia", name: "Velvia", about: "富士鲜艳。风光高饱和，反差大。", strength: 0.85),
    FujiSimulation(id: "astia", name: "ASTIA", about: "富士柔和。肤色柔，反差低。"),
    FujiSimulation(id: "classicchrome", name: "Classic Chrome", about: "低饱和，暗部偏硬的纪实色。"),
    FujiSimulation(id: "realaace", name: "Reala Ace", about: "真实中性，影调略硬。"),
    FujiSimulation(id: "proneg", name: "PRO Neg. Std", about: "人像负片。肤色干净，饱和低。"),
    FujiSimulation(id: "classicneg", name: "Classic Neg.", about: "经典负片。暖阴影，冷高光。"),
    FujiSimulation(id: "eterna", name: "ETERNA", about: "电影负片。低饱和，高光柔和。"),
    FujiSimulation(id: "eternabb", name: "ETERNA 跳漂白", about: "低饱和、高反差的电影冲洗。"),
    FujiSimulation(id: "acros", name: "ACROS", about: "富士黑白。阴影细节足。"),
].map { ($0.id, $0) })

/// Keep in sync with `packages` in Tools/ImportFujiLUTs.swift and the `fx-` families in LookLibrary.
let fujiPackages: [FujiPackage] = [
    FujiPackage(id: "eterna55", model: "GFX ETERNA 55", simulations: ["provia", "velvia", "astia", "classicchrome", "realaace", "proneg", "classicneg", "eterna", "eternabb", "acros"]),
    FujiPackage(id: "gfx100ii", model: "GFX100 II", simulations: ["eterna", "eternabb"]),
    FujiPackage(id: "gfx100rf", model: "GFX100RF", simulations: ["eterna", "eternabb"]),
    FujiPackage(id: "xt30iii", model: "X-T30 III", simulations: ["eterna", "eternabb"]),
    FujiPackage(id: "x100vi", model: "X100VI", simulations: ["eterna", "eternabb"]),
]

// MARK: - HaldCLUT

struct ImportError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Raw 8-bit RGB triples of a HaldCLUT, read without color management.
struct Hald {
    let dimension: Int
    let rgb: [Float]

    init(url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImportError("读不了 \(url.path)")
        }
        let side = image.width
        let level = Int(round(cbrt(Double(side))))
        guard image.height == side, level * level * level == side, image.bitsPerComponent == 8 else {
            throw ImportError("不是 8-bit HaldCLUT：\(url.lastPathComponent) \(image.width)×\(image.height)")
        }
        let channels = image.bitsPerPixel / 8
        guard (1...4).contains(channels),
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw ImportError("像素格式不支持：\(url.lastPathComponent)")
        }
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(image.alphaInfo)
        let offset = (channels == 4 || channels == 2) && alphaFirst ? 1 : 0
        let gray = channels <= 2
        var rgb = [Float](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            let row = bytes + y * image.bytesPerRow
            for x in 0..<side {
                let pixel = row + x * channels + offset
                let index = (y * side + x) * 3
                rgb[index] = Float(pixel[0]) / 255
                rgb[index + 1] = Float(pixel[gray ? 0 : 1]) / 255
                rgb[index + 2] = Float(pixel[gray ? 0 : 2]) / 255
            }
        }
        dimension = level * level
        self.rgb = rgb
    }

    func lookup(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        let top = Float(dimension - 1)
        let position = SIMD3<Float>(r, g, b) * top
        let low = SIMD3<Int>(Int(position.x), Int(position.y), Int(position.z))
            .clamped(lowerBound: .zero, upperBound: SIMD3(repeating: dimension - 2))
        let t = position - SIMD3<Float>(Float(low.x), Float(low.y), Float(low.z))
        func at(_ dr: Int, _ dg: Int, _ db: Int) -> SIMD3<Float> {
            let index = ((low.x + dr) + (low.y + dg) * dimension + (low.z + db) * dimension * dimension) * 3
            return SIMD3(rgb[index], rgb[index + 1], rgb[index + 2])
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

// MARK: - 512 LUT PNG

let lattice = 64
let tileSide = 512

func lutPixels(from hald: Hald) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: tileSide * tileSide * 4)
    let top = Float(lattice - 1)
    for blue in 0..<lattice {
        let originX = (blue % 8) * lattice
        let originY = (blue / 8) * lattice
        for green in 0..<lattice {
            for red in 0..<lattice {
                let value = hald.lookup(Float(red) / top, Float(green) / top, Float(blue) / top)
                let index = ((originY + green) * tileSide + originX + red) * 4
                pixels[index] = UInt8((min(max(value.x, 0), 1) * 255).rounded())
                pixels[index + 1] = UInt8((min(max(value.y, 0), 1) * 255).rounded())
                pixels[index + 2] = UInt8((min(max(value.z, 0), 1) * 255).rounded())
            }
        }
    }
    return pixels
}

/// Reads back the lattice point the app's loader samples, to check the tile layout.
func latticeValue(_ pixels: [UInt8], red: Int, green: Int, blue: Int) -> SIMD3<Float> {
    let x = (blue % 8) * lattice + red
    let y = (blue / 8) * lattice + green
    let index = (y * tileSide + x) * 4
    return SIMD3(Float(pixels[index]), Float(pixels[index + 1]), Float(pixels[index + 2])) / 255
}

func writePNG(_ pixels: [UInt8], width: Int, gray: Bool, to url: URL) throws {
    let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
    let components = gray ? 1 : 4
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(
              width: width,
              height: width,
              bitsPerComponent: 8,
              bitsPerPixel: 8 * components,
              bytesPerRow: width * components,
              space: space,
              bitmapInfo: CGBitmapInfo(rawValue: gray ? 0 : CGImageAlphaInfo.noneSkipLast.rawValue),
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

// MARK: - Grain plates

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Float {
        Float(next() >> 40) / Float(1 << 24)
    }

    mutating func gaussian() -> Float {
        let u1 = max(Double(unit()), 1e-7)
        let u2 = Double(unit())
        return Float(sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2))
    }
}

func boxBlur(_ source: [Float], size: Int, radius: Int) -> [Float] {
    guard radius > 0 else { return source }
    let span = Float(radius * 2 + 1)
    var horizontal = [Float](repeating: 0, count: source.count)
    var destination = [Float](repeating: 0, count: source.count)
    for y in 0..<size {
        for x in 0..<size {
            var sum: Float = 0
            for offset in -radius...radius {
                sum += source[y * size + min(max(x + offset, 0), size - 1)]
            }
            horizontal[y * size + x] = sum / span
        }
    }
    for y in 0..<size {
        for x in 0..<size {
            var sum: Float = 0
            for offset in -radius...radius {
                sum += horizontal[min(max(y + offset, 0), size - 1) * size + x]
            }
            destination[y * size + x] = sum / span
        }
    }
    return destination
}

func grainPlate(size: Int, blur: Int, deviation: Float, seed: UInt64) -> [UInt8] {
    var generator = SplitMix64(state: seed)
    var pixels = (0..<(size * size)).map { _ in 0.5 + generator.gaussian() * 0.35 }
    pixels = boxBlur(pixels, size: size, radius: blur)
    let count = Float(pixels.count)
    let mean = pixels.reduce(0, +) / count
    let variance = pixels.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / count
    let scale = deviation / max(sqrt(variance), 0.0001)
    return pixels.map { UInt8((min(max(0.5 + ($0 - mean) * scale, 0.02), 0.98) * 255).rounded()) }
}

// MARK: - Catalog

func number(_ value: Float) -> String {
    let rounded = (value * 1000).rounded() / 1000
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
}

func quoted(_ text: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])
    return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
}

func catalogJSON() -> String {
    var lines = [#"  {"id": "original", "name": "原图", "about": "不套风格。"}"#]
    for look in builtIns {
        lines.append("  {\"id\": \(quoted(look.id)), \"name\": \(quoted(look.name)), \"about\": \(quoted(look.about)), \"grade\": \"builtIn\", \"filter\": \(quoted(look.filter))}")
    }
    for film in films {
        var fields = [
            "\"id\": \(quoted(film.id))",
            "\"name\": \(quoted(film.name))",
            "\"about\": \(quoted(film.about))",
            "\"grade\": \"lut\"",
            "\"lut\": \(quoted("film-\(film.id)"))",
            "\"strength\": \(number(film.strength))",
        ]
        if film.grain > 0 {
            fields.append("\"grain\": \(number(film.grain))")
            fields.append("\"grainPlate\": \(quoted(film.plate))")
        }
        if film.vignette > 0 { fields.append("\"vignette\": \(number(film.vignette))") }
        if film.halation > 0 { fields.append("\"halation\": \(number(film.halation))") }
        lines.append("  {" + fields.joined(separator: ", ") + "}")
    }
    for package in fujiPackages {
        for id in package.simulations {
            guard let simulation = fujiSimulations[id] else { fatalError("未知的富士模拟 \(id)") }
            let key = "\(package.id)-\(simulation.id)"
            lines.append("  {\"id\": \(quoted("fx-\(key)")), \"name\": \(quoted(simulation.name)), \"about\": \(quoted("\(package.model) 的 LUT。\(simulation.about)")), \"grade\": \"lut\", \"lut\": \(quoted("fuji-\(key)")), \"strength\": \(number(simulation.strength))}")
        }
    }
    return "[\n" + lines.joined(separator: ",\n") + "\n]\n"
}

// MARK: - Main

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--sources" {
    for film in films { print(film.source) }
    exit(0)
}
guard let sourceRoot = arguments.first.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
    fputs("用法：import-luts <hald-clut/HaldCLUT 目录>\n", stderr)
    exit(2)
}

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = repository.appendingPathComponent("AngieFilter/Resources", isDirectory: true)
let lutDirectory = resources.appendingPathComponent("FilmLUTs", isDirectory: true)
let grainDirectory = resources.appendingPathComponent("Grain", isDirectory: true)

do {
    precondition(Set(films.map(\.id)).count == films.count, "重复的 id")
    try FileManager.default.createDirectory(at: lutDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: grainDirectory, withIntermediateDirectories: true)

    var generator = SplitMix64(state: 0x5EED_C0DE)
    var written = Set<String>()
    var worst: Float = 0
    for film in films {
        let hald = try Hald(url: sourceRoot.appendingPathComponent(film.source))
        let pixels = lutPixels(from: hald)
        for _ in 0..<2000 {
            let red = Int(generator.next() % 64), green = Int(generator.next() % 64), blue = Int(generator.next() % 64)
            let expected = hald.lookup(Float(red) / 63, Float(green) / 63, Float(blue) / 63)
            let stored = latticeValue(pixels, red: red, green: green, blue: blue)
            let difference = expected - stored
            worst = max(worst, max(abs(difference.x), abs(difference.y), abs(difference.z)))
        }
        let name = "film-\(film.id).png"
        try writePNG(pixels, width: tileSide, gray: false, to: lutDirectory.appendingPathComponent(name))
        written.insert(name)
    }
    guard worst < 1.0 / 255 + 0.0001 else {
        throw ImportError("格点和 HaldCLUT 对不上，最大差 \(worst)")
    }

    for file in try FileManager.default.contentsOfDirectory(atPath: lutDirectory.path)
    where file.hasSuffix(".png") && !written.contains(file) {
        try FileManager.default.removeItem(at: lutDirectory.appendingPathComponent(file))
    }

    let fine = grainPlate(size: 512, blur: 1, deviation: 0.12, seed: 0xA46E_F11E)
    let coarse = grainPlate(size: 512, blur: 5, deviation: 0.22, seed: 0xC0A5_E000)
    try writePNG(fine, width: 512, gray: true, to: grainDirectory.appendingPathComponent("fine.png"))
    try writePNG(coarse, width: 512, gray: true, to: grainDirectory.appendingPathComponent("coarse.png"))

    try catalogJSON().write(to: resources.appendingPathComponent("Looks.json"), atomically: true, encoding: .utf8)
    print("wrote \(films.count) film LUTs, \(builtIns.count) built-in looks, 2 grain plates, Looks.json (max lattice error \(worst))")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
