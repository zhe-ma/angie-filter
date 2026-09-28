import CoreImage
import Foundation

/// Skin, tone, and halation after the color step. Recipe and LUT looks share this.
enum FilmFinish {
    static func apply(
        _ image: CIImage,
        fade: Float,
        shoulder: Float,
        halation: Float,
        skin: Float,
        quality: RenderQuality
    ) -> CIImage {
        var graded = applySkin(image, amount: skin)
        graded = applyTone(graded, fade: fade, shoulder: shoulder)
        graded = applyHalation(graded, amount: halation, quality: quality)
        return graded
    }

    /// Pulls saturation down inside a narrow orange band. Red clothes sit outside that band.
    private static let skinKernel: CIColorKernel? = CIColorKernel(source: """
    kernel vec4 skinGuard(__sample pixel, float amount) {
        vec3 color = pixel.rgb;
        float red = color.r;
        float green = color.g;
        float blue = color.b;
        float maxChannel = max(red, max(green, blue));
        float minChannel = min(red, min(green, blue));
        float delta = maxChannel - minChannel;
        if (delta < 0.045 || maxChannel < 0.12) {
            return pixel;
        }
        float hue = 0.0;
        if (maxChannel == red) {
            hue = (green - blue) / delta;
            if (hue < 0.0) {
                hue = hue + 6.0;
            }
        } else if (maxChannel == green) {
            hue = (blue - red) / delta + 2.0;
        } else {
            hue = (red - green) / delta + 4.0;
        }
        hue = hue * 60.0;
        float distance = abs(hue - 28.0);
        float window = 1.0 - smoothstep(6.0, 16.0, distance);
        float saturation = delta / max(maxChannel, 0.001);
        window = window * smoothstep(0.18, 0.38, saturation);
        float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float pull = amount * window * 0.55;
        vec3 guarded = mix(color, vec3(luma, luma, luma), pull);
        float nudge = amount * window * 0.06;
        guarded.r = min(guarded.r + nudge, 1.0);
        guarded.g = max(guarded.g - nudge, 0.0);
        return vec4(guarded, pixel.a);
    }
    """)

    private static func applySkin(_ image: CIImage, amount: Float) -> CIImage {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.001, let skinKernel else { return image }
        let extent = image.extent
        guard let graded = skinKernel.apply(extent: extent, arguments: [image, NSNumber(value: amount)]) else {
            return image
        }
        return graded.cropped(to: extent)
    }

    /// Lifts the black point by fade and rolls the top end by shoulder. Both zero skips the curve.
    private static func applyTone(_ image: CIImage, fade: Float, shoulder: Float) -> CIImage {
        let fade = min(max(fade, 0), 1)
        let shoulder = min(max(shoulder, 0), 1)
        guard fade > 0.001 || shoulder > 0.001 else { return image }
        let black = CGFloat(fade) * 0.12
        let shadow = black + 0.18 * (1 - CGFloat(fade) * 0.25)
        let mid = 0.50 - CGFloat(fade) * 0.015
        let highlight = 0.78 - CGFloat(shoulder) * 0.16
        let white = 1 - CGFloat(shoulder) * 0.06 - CGFloat(fade) * 0.025
        let output = rising([black, shadow, mid, highlight, white])
        return image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: output[0]),
            "inputPoint1": CIVector(x: 0.18, y: output[1]),
            "inputPoint2": CIVector(x: 0.50, y: output[2]),
            "inputPoint3": CIVector(x: 0.78, y: output[3]),
            "inputPoint4": CIVector(x: 1, y: output[4])
        ]).cropped(to: image.extent)
    }

    private static func rising(_ values: [CGFloat]) -> [CGFloat] {
        var result = values.map { min(max($0, 0), 1) }
        for index in 1..<result.count where result[index] < result[index - 1] + 0.01 {
            result[index] = min(1, result[index - 1] + 0.01)
        }
        return result
    }

    /// One blur of the highlight mask. The red fringe and a lighter white haze share that blur.
    private static func applyHalation(_ image: CIImage, amount: Float, quality: RenderQuality) -> CIImage {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.001 else { return image }
        let extent = image.extent
        guard extent.width > 1 else { return image }
        let fraction: CGFloat = quality == .preview ? 0.012 : 0.022
        let radius = max(2, extent.width * fraction)
        let gray = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1,
            kCIInputBrightnessKey: 0
        ]).cropped(to: extent)
        let mask = gray.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.55, y: 0),
            "inputPoint2": CIVector(x: 0.72, y: 0.08),
            "inputPoint3": CIVector(x: 0.88, y: 0.65),
            "inputPoint4": CIVector(x: 1, y: 1)
        ]).cropped(to: extent)
        let glow = mask.applyingFilter("CIGaussianBlur", parameters: [
            kCIInputRadiusKey: radius
        ]).cropped(to: extent)
        let tint = glow.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1.15, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.38, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.12, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).cropped(to: extent)
        let screened = tint.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ]).cropped(to: extent)
        let withHalo = GradeApplicator.mix(image, screened, amount: amount)
        let hazed = glow.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: withHalo
        ]).cropped(to: extent)
        return GradeApplicator.mix(withHalo, hazed, amount: amount * 0.28)
    }
}
