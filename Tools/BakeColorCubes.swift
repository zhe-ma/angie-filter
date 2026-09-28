#!/usr/bin/env swift
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Authoring source for every look. Re-run from the repo root:
//   swift Tools/BakeColorCubes.swift
// Color (temperature, tint, contrast, saturation, brightness, hue) is baked
// into a 65³ Display P3 cube. Clarity, grain, vignette, fade, shoulder,
// halation, and skin stay spatial and are written to Looks.json for the app.

let dimension = 65
let coarseGrainIDs: Set<String> = [
    "neg", "nostalgia", "superia", "portra800", "gold", "ultramax",
    "colorplus", "trix", "cs800t", "hp5", "fp4", "sx70", "p600"
]

struct Spec {
    var id: String
    var name: String
    var about: String
    var contrast: Float = 1
    var saturation: Float = 1
    var brightness: Float = 0
    var temperature: Float = 6500
    var tint: Float = 0
    var hue: Float = 0
    var clarity: Float = 0
    var grain: Float = 0
    var vignette: Float = 0
    /// Teal shadows and warm skin, baked into the cube. Only the trailer look uses this.
    var splitTone = false

    var isOriginal: Bool { id == "original" }

    var grainPlate: String {
        guard grain > 0.001 else { return "none" }
        return coarseGrainIDs.contains(id) ? "coarse" : "fine"
    }
}

struct CatalogItem: Codable {
    let id: String
    let name: String
    let about: String
    let clarity: Float
    let grain: Float
    let grainPlate: String
    let vignette: Float
    let fade: Float
    let shoulder: Float
    let halation: Float
    let skin: Float
}

struct FinishSpec {
    var fade: Float = 0
    var shoulder: Float = 0
    var halation: Float = 0
    var skin: Float = 0
}

let finishByID: [String: FinishSpec] = [
    "natural": FinishSpec(fade: 0.04, shoulder: 0.08),
    "classic": FinishSpec(fade: 0.10, shoulder: 0.16, skin: 0.25),
    "bright": FinishSpec(fade: 0.02, shoulder: 0.06),
    "mono": FinishSpec(fade: 0.06, shoulder: 0.10),
    "standard": FinishSpec(fade: 0.04, shoulder: 0.08),
    "vivid": FinishSpec(fade: 0.02, shoulder: 0.06),
    "soft": FinishSpec(fade: 0.10, shoulder: 0.10, skin: 0.25),
    "chrome": FinishSpec(fade: 0.06, shoulder: 0.18),
    "neg": FinishSpec(fade: 0.16, shoulder: 0.14, skin: 0.25),
    "nostalgia": FinishSpec(fade: 0.18, shoulder: 0.12, skin: 0.20),
    "real": FinishSpec(fade: 0.08, shoulder: 0.10),
    "cinema": FinishSpec(fade: 0.10, shoulder: 0.16),
    "bleach": FinishSpec(fade: 0.08, shoulder: 0.20),
    "portrait": FinishSpec(fade: 0.12, shoulder: 0.12, skin: 0.30),
    "portrait-hi": FinishSpec(fade: 0.14, shoulder: 0.12, skin: 0.30),
    "acros": FinishSpec(fade: 0.05, shoulder: 0.12),
    "pro400h": FinishSpec(fade: 0.16, shoulder: 0.12, skin: 0.30),
    "superia": FinishSpec(fade: 0.14, shoulder: 0.12, skin: 0.20),
    "portra160": FinishSpec(fade: 0.12, shoulder: 0.10, skin: 0.35),
    "portra400": FinishSpec(fade: 0.14, shoulder: 0.12, skin: 0.35),
    "portra800": FinishSpec(fade: 0.16, shoulder: 0.12, skin: 0.35),
    "gold": FinishSpec(fade: 0.16, shoulder: 0.10, skin: 0.30),
    "ektar": FinishSpec(fade: 0.04, shoulder: 0.14),
    "ultramax": FinishSpec(fade: 0.14, shoulder: 0.10, skin: 0.20),
    "colorplus": FinishSpec(fade: 0.16, shoulder: 0.10, skin: 0.15),
    "kodachrome": FinishSpec(fade: 0.06, shoulder: 0.18),
    "ektachrome": FinishSpec(fade: 0.04, shoulder: 0.12),
    "trix": FinishSpec(fade: 0.06, shoulder: 0.14),
    "tmax": FinishSpec(fade: 0.03, shoulder: 0.10),
    "cs800t": FinishSpec(fade: 0.08, shoulder: 0.16, halation: 0.35),
    "cs50d": FinishSpec(fade: 0.06, shoulder: 0.12),
    "cs400d": FinishSpec(fade: 0.08, shoulder: 0.12),
    "v250d": FinishSpec(fade: 0.06, shoulder: 0.14, skin: 0.20),
    "v500t": FinishSpec(fade: 0.10, shoulder: 0.16, halation: 0.35),
    "trailer": FinishSpec(fade: 0.06, shoulder: 0.20, halation: 0.24, skin: 0.15),
    "positive": FinishSpec(fade: 0.04, shoulder: 0.08),
    "negative": FinishSpec(fade: 0.16, shoulder: 0.12, skin: 0.20),
    "hibw": FinishSpec(fade: 0.08, shoulder: 0.12),
    "hncs": FinishSpec(fade: 0.03, shoulder: 0.06),
    "hp5": FinishSpec(fade: 0.08, shoulder: 0.14),
    "delta": FinishSpec(fade: 0.04, shoulder: 0.10),
    "fp4": FinishSpec(fade: 0.06, shoulder: 0.12),
    "xp2": FinishSpec(fade: 0.05, shoulder: 0.08),
    "sx70": FinishSpec(fade: 0.20, shoulder: 0.10),
    "p600": FinishSpec(fade: 0.18, shoulder: 0.10),
    "canon": FinishSpec(fade: 0.02, shoulder: 0.04),
    "nikon": FinishSpec(fade: 0.02, shoulder: 0.04),
    "sony": FinishSpec(fade: 0.02, shoulder: 0.04)
]

func spec(
    _ id: String,
    _ name: String,
    _ about: String,
    contrast: Float = 1,
    saturation: Float = 1,
    brightness: Float = 0,
    temperature: Float = 6500,
    tint: Float = 0,
    hue: Float = 0,
    clarity: Float = 0,
    grain: Float = 0,
    vignette: Float = 0,
    splitTone: Bool = false
) -> Spec {
    Spec(
        id: id,
        name: name,
        about: about,
        contrast: contrast,
        saturation: saturation,
        brightness: brightness,
        temperature: temperature,
        tint: tint,
        hue: hue,
        clarity: clarity,
        grain: grain,
        vignette: vignette,
        splitTone: splitTone
    )
}

let looks: [Spec] = [
    spec("original", "原图", "不套风格。"),

    spec("natural", "自然", "现代徕卡数码色彩。略暖，肤色稳，微对比明显。", contrast: 1.06, saturation: 1.08, temperature: 5800, clarity: 0.35, grain: 0.05),
    spec("classic", "经典", "胶片时代的 M 型色彩。红色更厚，高光更早滚落。", contrast: 0.98, saturation: 1.12, temperature: 5200, clarity: 0.2, grain: 0.12, vignette: 0.6),
    spec("bright", "鲜明", "对比更高，黑色更实，色彩仍然自然。", contrast: 1.18, saturation: 1.06, temperature: 6400, clarity: 0.25),
    spec("mono", "单色", "黑白，阴影有层次，细颗粒。", contrast: 1.2, saturation: 0, clarity: 0.3, grain: 0.2, vignette: 0.35),

    spec("standard", "标准", "Provia。中性参照。", contrast: 1.04, saturation: 1.06),
    spec("vivid", "鲜艳", "Velvia。风景向，绿和红分开。", contrast: 1.12, saturation: 1.55, hue: -8),
    spec("soft", "柔和", "Astia。人像优先，对比低。", contrast: 0.92, saturation: 0.82, brightness: 0.03, temperature: 6000),
    spec("chrome", "经典铬黄", "Classic Chrome。饱和低，暗部更硬。", contrast: 1.16, saturation: 0.62, temperature: 5600, clarity: 0.15, grain: 0.12, vignette: 0.35),
    spec("neg", "经典负片", "Classic Neg。暖阴影，冷高光。", contrast: 1.05, saturation: 0.92, temperature: 5400, hue: -8, grain: 0.28, vignette: 0.7),
    spec("nostalgia", "怀旧负片", "Nostalgic Neg。琥珀色。", contrast: 0.96, saturation: 1.15, brightness: 0.03, temperature: 5000, grain: 0.24, vignette: 0.6),
    spec("real", "真实", "Reala Ace。色彩中性，影调更硬。", contrast: 1.14, saturation: 1.02, clarity: 0.15),
    spec("cinema", "电影", "Eterna。低对比，高光留得住。", contrast: 0.86, saturation: 0.72, brightness: 0.04, vignette: 0.4),
    spec("bleach", "漂白", "Eterna Bleach Bypass。对比高，颜色抽掉。", contrast: 1.28, saturation: 0.45, grain: 0.16, vignette: 0.4),
    spec("portrait", "人像", "Pro Neg. Std。肤色干净，饱和低。", contrast: 0.98, saturation: 0.78, brightness: 0.02, temperature: 5900),
    spec("portrait-hi", "人像高", "Pro Neg. Hi。人像肤色，对比更高。", contrast: 1.1, saturation: 0.8, temperature: 5800),
    spec("acros", "黑白", "Acros。阴影有细节，颗粒更像胶片。", contrast: 1.1, saturation: 0, brightness: 0.02, clarity: 0.25, grain: 0.4, vignette: 0.3),
    spec("pro400h", "400H", "Pro 400H。粉彩，肤色软。", contrast: 0.9, saturation: 0.8, brightness: 0.04, temperature: 5700, grain: 0.14),
    spec("superia", "超级丽爱", "Superia 400。消费负片，绿色更明显。", contrast: 1.06, saturation: 1.1, temperature: 5600, hue: 10, grain: 0.22),

    spec("portra160", "肖像 160", "Portra 160。颗粒最细，肤色最柔。", contrast: 0.92, saturation: 0.94, brightness: 0.03, temperature: 5600, grain: 0.08),
    spec("portra400", "肖像 400", "Portra 400。人像胶片里最常用的一款。", contrast: 0.98, saturation: 1.0, brightness: 0.02, temperature: 5400, grain: 0.2, vignette: 0.25),
    spec("portra800", "肖像 800", "Portra 800。更暖，颗粒更明显。", contrast: 0.95, saturation: 0.9, brightness: 0.02, temperature: 5000, grain: 0.34, vignette: 0.35),
    spec("gold", "金 200", "Gold 200。日光消费卷，偏金黄。", contrast: 1.06, saturation: 1.15, temperature: 4800, hue: -6, grain: 0.2, vignette: 0.35),
    spec("ektar", "爱克塔", "Ektar 100。风景高彩，细颗粒。", contrast: 1.18, saturation: 1.55, hue: -6),
    spec("ultramax", "日常 400", "Ultramax 400。对比高，颗粒粗，偏暖。", contrast: 1.12, saturation: 1.22, temperature: 5200, grain: 0.3),
    spec("colorplus", "彩色+", "ColorPlus。更闷，略偏绿。", contrast: 1.02, saturation: 0.86, temperature: 5400, hue: 8, grain: 0.22),
    spec("kodachrome", "柯达克罗姆", "Kodachrome 64。反转片，红色密，对比实。", contrast: 1.16, saturation: 1.25, temperature: 5200, hue: -12, grain: 0.06),
    spec("ektachrome", "爱克塔克罗姆", "Ektachrome。反转片，蓝色更冷。", contrast: 1.12, saturation: 1.14, temperature: 7200, hue: 12),
    spec("trix", "黑白 400", "Tri-X 400。粗颗粒新闻黑白。", contrast: 1.26, saturation: 0, grain: 0.48),
    spec("tmax", "黑白细", "T-Max 100。颗粒细，影调平滑。", contrast: 1.08, saturation: 0, grain: 0.08),

    spec("cs800t", "800T", "Cinestill 800T。钨丝灯光，偏青。", contrast: 1.08, saturation: 0.84, temperature: 8200, hue: 14, grain: 0.32, vignette: 0.5),
    spec("cs50d", "50D", "Cinestill 50D。日光电影卷，干净，略暖。", contrast: 1.02, saturation: 1.05, temperature: 6000, grain: 0.06),
    spec("cs400d", "400D", "Cinestill 400D。日光，颗粒介于 50D 和 800T 之间。", contrast: 1.04, saturation: 1.02, temperature: 5800, grain: 0.16),
    spec("v250d", "日光 250", "Vision3 250D。电影日光底片，肤色自然。", contrast: 1.04, saturation: 1.06, temperature: 6100, grain: 0.08),
    spec("v500t", "灯光 500", "Vision3 500T。钨丝灯电影底片。", contrast: 1.06, saturation: 0.92, temperature: 7600, hue: 8, grain: 0.14),
    spec("trailer", "大片", "电影宣传片。阴影偏青，肤色和灯光偏暖。", contrast: 1.14, saturation: 1.06, temperature: 6000, clarity: 0.2, grain: 0.16, vignette: 0.4, splitTone: true),

    spec("positive", "正片", "GR 正片。街拍直出，略偏青，对比清楚。", contrast: 1.16, saturation: 1.12, hue: 6, clarity: 0.2),
    spec("negative", "负片", "GR 负片。更软，略暖。", contrast: 0.94, saturation: 0.96, temperature: 5800, grain: 0.1),
    spec("hibw", "高对比黑白", "GR 高对比黑白。黑白两极更开。", contrast: 1.35, saturation: 0, grain: 0.16, vignette: 0.4),

    spec("hncs", "自然色", "哈苏自然色。干净、准确，几乎不加风格。", contrast: 1.03, saturation: 1.04, clarity: 0.08),

    spec("hp5", "HP5", "HP5 Plus。经典颗粒。", contrast: 1.16, saturation: 0, grain: 0.4),
    spec("delta", "德尔塔", "Delta 100。颗粒细，影调平。", contrast: 1.06, saturation: 0, grain: 0.06),
    spec("fp4", "FP4", "FP4 Plus。传统黑白，颗粒中等。", contrast: 1.12, saturation: 0, grain: 0.2),
    spec("xp2", "XP2", "XP2。彩色工艺的黑白，颗粒更润。", contrast: 1.02, saturation: 0, brightness: 0.03, grain: 0.1),

    spec("sx70", "SX-70", "SX-70。褪色、偏暖、对比低，四角更暗。", contrast: 0.86, saturation: 0.9, brightness: 0.05, temperature: 5000, grain: 0.22, vignette: 1.1),
    spec("p600", "600", "600。比 SX-70 更实，颜色更跳。", contrast: 1.05, saturation: 1.06, temperature: 5400, grain: 0.2, vignette: 0.7),

    spec("canon", "佳能", "佳能直出。略暖，对比清楚。", contrast: 1.08, saturation: 1.08, temperature: 6000),
    spec("nikon", "尼康", "尼康鲜艳。绿和蓝更开。", contrast: 1.1, saturation: 1.28, hue: -4),
    spec("sony", "索尼", "索尼直出。偏中性，略冷。", contrast: 1.04, saturation: 1.0, temperature: 6800, hue: 4)
]

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
    var horizontal = [Float](repeating: 0, count: source.count)
    var destination = [Float](repeating: 0, count: source.count)
    for y in 0..<size {
        for x in 0..<size {
            var sum: Float = 0
            let span = radius * 2 + 1
            for offset in -radius...radius {
                let sampleX = min(max(x + offset, 0), size - 1)
                sum += source[y * size + sampleX]
            }
            horizontal[y * size + x] = sum / Float(span)
        }
    }
    for y in 0..<size {
        for x in 0..<size {
            var sum: Float = 0
            let span = radius * 2 + 1
            for offset in -radius...radius {
                let sampleY = min(max(y + offset, 0), size - 1)
                sum += horizontal[sampleY * size + x]
            }
            destination[y * size + x] = sum / Float(span)
        }
    }
    return destination
}

func grainPlate(size: Int, blur: Int, deviation: Float, seed: UInt64) -> [UInt8] {
    var generator = SplitMix64(state: seed)
    var pixels = [Float](repeating: 0, count: size * size)
    for index in pixels.indices {
        pixels[index] = 0.5 + generator.gaussian() * 0.35
    }
    pixels = boxBlur(pixels, size: size, radius: blur)
    let count = Float(pixels.count)
    let mean = pixels.reduce(0, +) / count
    let variance = pixels.reduce(Float(0)) { partial, value in
        let delta = value - mean
        return partial + delta * delta
    } / count
    let scale = deviation / max(sqrt(variance), 0.0001)
    return pixels.map { value in
        let shaped = min(max(0.5 + (value - mean) * scale, 0.02), 0.98)
        return UInt8((shaped * 255).rounded())
    }
}

func writePNG(_ pixels: [UInt8], size: Int, to url: URL) throws {
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData) else {
        throw BakeError("无法创建颗粒图")
    }
    guard let image = CGImage(
        width: size,
        height: size,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: size,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: 0),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw BakeError("无法编码颗粒图")
    }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw BakeError("无法写入 \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw BakeError("颗粒图写入失败 \(url.path)")
    }
}

struct BakeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let resources = root.appendingPathComponent("AngieFilter/Resources", isDirectory: true)
let cubeDirectory = resources.appendingPathComponent("ColorCubes", isDirectory: true)
let grainDirectory = resources.appendingPathComponent("Grain", isDirectory: true)

guard let displayP3 = CGColorSpace(name: CGColorSpace.displayP3) else {
    fputs("没有 Display P3\n", stderr)
    exit(1)
}

let context = CIContext(options: [
    .workingColorSpace: displayP3,
    .outputColorSpace: displayP3,
    .workingFormat: CIFormat.RGBAf.rawValue,
    .outputPremultiplied: false,
    .cacheIntermediates: false
])

let width = dimension * dimension
let height = dimension
let pixelCount = width * height

func latticeImage() -> (CIImage, Data) {
    var pixels = [Float](repeating: 0, count: pixelCount * 4)
    let scale = Float(dimension - 1)
    for blue in 0..<dimension {
        for green in 0..<dimension {
            for red in 0..<dimension {
                let x = red + green * dimension
                let index = (blue * width + x) * 4
                pixels[index] = Float(red) / scale
                pixels[index + 1] = Float(green) / scale
                pixels[index + 2] = Float(blue) / scale
                pixels[index + 3] = 1
            }
        }
    }
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    let image = CIImage(
        bitmapData: data,
        bytesPerRow: width * MemoryLayout<Float>.size * 4,
        size: CGSize(width: width, height: height),
        format: .RGBAf,
        colorSpace: displayP3
    )
    return (image, data)
}

func render(_ image: CIImage) -> [Float] {
    var output = [Float](repeating: 0, count: pixelCount * 4)
    output.withUnsafeMutableBytes { raw in
        context.render(
            image,
            toBitmap: raw.baseAddress!,
            rowBytes: width * MemoryLayout<Float>.size * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf,
            colorSpace: displayP3
        )
    }
    return output
}

func sample(_ buffer: [Float], red: Int, green: Int, blue: Int, flipY: Bool) -> (Float, Float, Float) {
    let row = flipY ? (dimension - 1 - blue) : blue
    let index = (row * width + red + green * dimension) * 4
    return (buffer[index], buffer[index + 1], buffer[index + 2])
}

func latticeError(_ buffer: [Float], flipY: Bool) -> Float {
    let scale = Float(dimension - 1)
    var worst: Float = 0
    for blue in stride(from: 0, to: dimension, by: 8) {
        for green in stride(from: 0, to: dimension, by: 8) {
            for red in stride(from: 0, to: dimension, by: 8) {
                let color = sample(buffer, red: red, green: green, blue: blue, flipY: flipY)
                worst = max(worst, abs(color.0 - Float(red) / scale))
                worst = max(worst, abs(color.1 - Float(green) / scale))
                worst = max(worst, abs(color.2 - Float(blue) / scale))
            }
        }
    }
    return worst
}

func applyColor(_ image: CIImage, _ look: Spec) -> CIImage {
    var graded = image
    if look.temperature != 6500 || look.tint != 0 {
        graded = graded.applyingFilter("CITemperatureAndTint", parameters: [
            "inputNeutral": CIVector(x: 6500, y: 0),
            "inputTargetNeutral": CIVector(x: CGFloat(look.temperature), y: CGFloat(look.tint))
        ])
    }
    graded = graded.applyingFilter("CIColorControls", parameters: [
        kCIInputContrastKey: look.contrast,
        kCIInputSaturationKey: look.saturation,
        kCIInputBrightnessKey: look.brightness
    ])
    if look.hue != 0 {
        graded = graded.applyingFilter("CIHueAdjust", parameters: [
            kCIInputAngleKey: look.hue * Float.pi / 180
        ])
    }
    if look.splitTone {
        graded = trailerSplit(graded)
    }
    return graded.cropped(to: image.extent)
}

/// Shadows and sky toward teal, orange skin and highlights toward warm. Small on purpose.
private let trailerSplitKernel: CIColorKernel? = CIColorKernel(source: """
kernel vec4 trailerSplit(__sample pixel) {
    vec3 color = pixel.rgb;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float maxChannel = max(color.r, max(color.g, color.b));
    float minChannel = min(color.r, min(color.g, color.b));
    float delta = maxChannel - minChannel;
    float hue = 0.0;
    if (delta > 0.0001) {
        if (maxChannel == color.r) {
            hue = (color.g - color.b) / delta;
            if (hue < 0.0) { hue = hue + 6.0; }
        } else if (maxChannel == color.g) {
            hue = (color.b - color.r) / delta + 2.0;
        } else {
            hue = (color.r - color.g) / delta + 4.0;
        }
        hue = hue * 60.0;
    }
    float colorful = smoothstep(0.04, 0.12, delta);
    float redDistance = min(abs(hue), abs(hue - 360.0));
    float red = colorful * (1.0 - smoothstep(10.0, 28.0, redDistance));
    float orange = colorful * (1.0 - smoothstep(10.0, 26.0, abs(hue - 26.0)));
    float green = colorful * (1.0 - smoothstep(16.0, 42.0, abs(hue - 125.0)));
    float blue = colorful * (1.0 - smoothstep(16.0, 46.0, abs(hue - 215.0)));
    float shadow = 1.0 - smoothstep(0.16, 0.52, luma);
    float highlight = smoothstep(0.58, 0.90, luma);

    vec3 result = color;
    float shadowAmount = 0.08 * shadow * (1.0 - max(orange, red));
    result.r = result.r - shadowAmount * 0.45;
    result.g = result.g + shadowAmount * 0.16;
    result.b = result.b + shadowAmount * 0.38;

    float blueAmount = 0.12 * blue;
    result.r = result.r - blueAmount * 0.26;
    result.g = result.g + blueAmount * 0.20;

    float greenAmount = 0.22 * green;
    result.r = result.r - greenAmount * 0.06;
    result.b = result.b + greenAmount * 0.42;

    float orangeAmount = 0.08 * orange * (1.0 - red * 0.75);
    result.r = result.r + orangeAmount * 0.16;
    result.b = result.b - orangeAmount * 0.22;

    float highlightAmount = 0.05 * highlight * (1.0 - blue * 0.75) * (1.0 - orange * 0.8);
    result.r = result.r + highlightAmount * 0.28;
    result.b = result.b - highlightAmount * 0.24;

    return vec4(result, pixel.a);
}
""")

func trailerSplit(_ image: CIImage) -> CIImage {
    guard let trailerSplitKernel,
          let graded = trailerSplitKernel.apply(extent: image.extent, arguments: [image]) else {
        fputs("大片分色内核没有建起来\n", stderr)
        exit(1)
    }
    return graded.cropped(to: image.extent)
}

func appendFloat16(_ value: Float, to data: inout Data) {
    var bits = Float16(value).bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
}

func cubeFile(from buffer: [Float], flipY: Bool) -> Data {
    var data = Data(capacity: 8 + pixelCount * 6)
    data.append(contentsOf: Array("AC65".utf8))
    data.append(contentsOf: [UInt8(dimension & 0xFF), UInt8((dimension >> 8) & 0xFF), 2, 0])
    for blue in 0..<dimension {
        for green in 0..<dimension {
            for red in 0..<dimension {
                let color = sample(buffer, red: red, green: green, blue: blue, flipY: flipY)
                appendFloat16(color.0, to: &data)
                appendFloat16(color.1, to: &data)
                appendFloat16(color.2, to: &data)
            }
        }
    }
    return data
}

func expand(_ file: Data) -> Data? {
    guard file.count == 8 + pixelCount * 6, file.prefix(4) == Data("AC65".utf8) else { return nil }
    var floats = [Float](repeating: 1, count: pixelCount * 4)
    file.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        for index in 0..<pixelCount {
            let source = 8 + index * 6
            let destination = index * 4
            for channel in 0..<3 {
                let offset = source + channel * 2
                let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                floats[destination + channel] = Float(Float16(bitPattern: bits))
            }
        }
    }
    return floats.withUnsafeBufferPointer { Data(buffer: $0) }
}

func renderPixel(red: Float, green: Float, blue: Float, look: Spec, cube: Data?) -> (Float, Float, Float) {
    let pixel: [Float] = [red, green, blue, 1]
    let sourceData = pixel.withUnsafeBufferPointer { Data(buffer: $0) }
    let source = CIImage(
        bitmapData: sourceData,
        bytesPerRow: 16,
        size: CGSize(width: 1, height: 1),
        format: .RGBAf,
        colorSpace: displayP3
    )
    let graded: CIImage
    if let cube {
        graded = source.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": cube,
            "inputColorSpace": displayP3,
            "inputExtrapolate": true
        ]).cropped(to: source.extent)
    } else {
        graded = applyColor(source, look)
    }
    var output = [Float](repeating: 0, count: 4)
    output.withUnsafeMutableBytes { raw in
        context.render(
            graded,
            toBitmap: raw.baseAddress!,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: displayP3
        )
    }
    return (output[0], output[1], output[2])
}

let probes: [(String, Float, Float, Float)] = [
    ("肤色", 0.87, 0.68, 0.55),
    ("天空", 0.35, 0.55, 0.85),
    ("绿植", 0.20, 0.55, 0.22),
    ("红衣", 0.75, 0.15, 0.12),
    ("高光", 0.96, 0.96, 0.94),
    ("暗部", 0.04, 0.04, 0.05)
]

do {
    try FileManager.default.createDirectory(at: cubeDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: grainDirectory, withIntermediateDirectories: true)

    let fine = grainPlate(size: 512, blur: 1, deviation: 0.12, seed: 0xA46E_F11E)
    let coarse = grainPlate(size: 512, blur: 5, deviation: 0.22, seed: 0xC0A5_E000)
    try writePNG(fine, size: 512, to: grainDirectory.appendingPathComponent("fine.png"))
    try writePNG(coarse, size: 512, to: grainDirectory.appendingPathComponent("coarse.png"))

    let items = looks.map {
        let finish = finishByID[$0.id] ?? FinishSpec()
        return CatalogItem(
            id: $0.id,
            name: $0.name,
            about: $0.about,
            clarity: $0.clarity,
            grain: $0.grain,
            grainPlate: $0.grainPlate,
            vignette: $0.vignette,
            fade: finish.fade,
            shoulder: finish.shoulder,
            halation: finish.halation,
            skin: finish.skin
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let json = try encoder.encode(items)
    try json.write(to: resources.appendingPathComponent("Looks.json"))

    let (identityImage, identityData) = latticeImage()
    _ = identityData
    let identityBuffer = render(identityImage)
    let straightError = latticeError(identityBuffer, flipY: false)
    let flippedError = latticeError(identityBuffer, flipY: true)
    let flipY = flippedError < straightError
    let layoutError = min(straightError, flippedError)
    print(String(format: "lattice error %.5f, flipY %@", layoutError, flipY ? "yes" : "no"))
    guard layoutError < 0.02 else {
        throw BakeError("色彩格子方向不对，误差 \(layoutError)")
    }

    var worst: Float = 0
    var worstLabel = ""
    for look in looks where !look.isOriginal {
        let graded = render(applyColor(identityImage, look))
        let file = cubeFile(from: graded, flipY: flipY)
        guard file.count == 8 + pixelCount * 6, let expanded = expand(file) else {
            throw BakeError("\(look.id) 立方体尺寸不对")
        }
        try file.write(to: cubeDirectory.appendingPathComponent("\(look.id).acube"))
        for probe in probes {
            let live = renderPixel(red: probe.1, green: probe.2, blue: probe.3, look: look, cube: nil)
            let sampled = renderPixel(red: probe.1, green: probe.2, blue: probe.3, look: look, cube: expanded)
            // CIColorCube clamps the displayed result to 0...1. Compare that range,
            // which is what the preview and the HEIC file keep.
            let delta = max(
                abs(min(max(live.0, 0), 1) - min(max(sampled.0, 0), 1)),
                abs(min(max(live.1, 0), 1) - min(max(sampled.1, 0), 1)),
                abs(min(max(live.2, 0), 1) - min(max(sampled.2, 0), 1))
            )
            if delta > worst {
                worst = delta
                worstLabel = "\(look.name) \(probe.0)"
            }
        }
        print("baked \(look.id)")
    }

    let cubeNames = Set(looks.filter { !$0.isOriginal }.map(\.id))
    for url in try FileManager.default.contentsOfDirectory(at: cubeDirectory, includingPropertiesForKeys: nil) where url.pathExtension == "acube" {
        if !cubeNames.contains(url.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }

    print(String(format: "worst cube error %.5f at %@", worst, worstLabel))
    guard worst < 0.04 else {
        throw BakeError("立方体和现场调色差得太多：\(worstLabel) \(worst)")
    }
    let baked = looks.filter { !$0.isOriginal }.count
    print("wrote \(baked) cubes, 2 grain plates, Looks.json")
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
