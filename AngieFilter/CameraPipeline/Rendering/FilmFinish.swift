import CoreImage
import Foundation

/// Fade, halation, grain, and vignette after the color step. Only built-in Core Image filters.
enum FilmFinish {
    static func apply(
        _ image: CIImage,
        adjustment: LookAdjustment,
        grainPlate: GrainPlateKind,
        quality: RenderQuality,
        grainShift: CGPoint = .zero
    ) -> CIImage {
        var finished = applyFade(image, amount: adjustment.fade)
        if quality != .thumbnail {
            finished = applyHalation(finished, amount: adjustment.halation, quality: quality)
            finished = applyGrain(finished, plate: grainPlate, amount: adjustment.grain, shift: grainShift)
        }
        return applyVignette(finished, amount: adjustment.vignette)
    }

    /// Lifts the black point. At 1 black sits at 0.12 and white drops slightly.
    private static func applyFade(_ image: CIImage, amount: Float) -> CIImage {
        let fade = CGFloat(min(max(amount, 0), 1))
        guard fade > 0.001 else { return image }
        let black = fade * 0.12
        let output = rising([black, black + 0.18 * (1 - fade * 0.25), 0.50 - fade * 0.015, 0.78, 1 - fade * 0.025])
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
        let fraction: CGFloat = quality == .still ? 0.022 : 0.012
        let radius = max(2, extent.width * fraction)
        let mask = luminance(image).applyingFilter("CIToneCurve", parameters: [
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

    /// A tiled plate in soft light, masked so grain sits in the shadows and pure white stays clean.
    /// A look without a plate that has its grain raised uses the fine plate.
    /// `shift` moves the plate as a fraction of one tile, so a caller can give each frame its own grain.
    private static func applyGrain(_ image: CIImage, plate plateKind: GrainPlateKind, amount: Float, shift: CGPoint) -> CIImage {
        let resolved: GrainPlateKind = plateKind == .none ? .fine : plateKind
        guard amount > 0.001, let plate = GrainLibrary.image(for: resolved) else { return image }
        let extent = image.extent
        guard extent.width > 1, plate.extent.width > 1 else { return image }

        let repeats: CGFloat = resolved == .coarse ? 1.7 : 3
        let scale = (extent.width / repeats) / plate.extent.width
        let tile = plate.extent.width * scale
        let tiled = plate
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIAffineTile")
            .transformed(by: CGAffineTransform(translationX: (shift.x * tile).rounded(), y: (shift.y * tile).rounded()))
            .cropped(to: extent)
        let soft = tiled.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ]).cropped(to: extent)
        let mask = luminance(image).applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0.15),
            "inputPoint1": CIVector(x: 0.18, y: 1),
            "inputPoint2": CIVector(x: 0.42, y: 0.72),
            "inputPoint3": CIVector(x: 0.72, y: 0.18),
            "inputPoint4": CIVector(x: 1, y: 0)
        ]).cropped(to: extent)
        let masked = soft.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
        return GradeApplicator.mix(image, masked, amount: amount)
    }

    /// `CIVignetteEffect` around the center. Amount 1 darkens the corners by about a third.
    private static func applyVignette(_ image: CIImage, amount: Float) -> CIImage {
        let amount = min(max(amount, 0), 1.5)
        guard amount > 0.001 else { return image }
        let extent = image.extent
        let halfDiagonal = hypot(extent.width, extent.height) / 2
        guard halfDiagonal > 1 else { return image }
        return image.applyingFilter("CIVignetteEffect", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            kCIInputRadiusKey: halfDiagonal * 0.85,
            kCIInputIntensityKey: amount * 0.35,
            "inputFalloff": 0.6
        ]).cropped(to: extent)
    }

    private static func luminance(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1,
            kCIInputBrightnessKey: 0
        ]).cropped(to: image.extent)
    }
}
