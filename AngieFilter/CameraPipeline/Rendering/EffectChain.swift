import CoreImage
import Foundation

/// The 实验室 looks. Each recipe keeps the stage order and the numbers from its source report.
/// Values the reports leave out are ours; design/competitor-effects.md lists which is which.
enum EffectChain {
    /// Pixel moves. They run before color so the strength mix blends two moved images.
    static func lens(_ image: CIImage, grade: EffectGrade) -> CIImage {
        switch grade.recipe {
        case .dazzFisheyeWide:
            return fisheye(image, radius: 0.55)
        case .dazzFisheyeFull:
            return circleMask(fisheye(prescaled(image, by: 0.87), radius: 0.68, over: image.extent))
        default:
            return image
        }
    }

    static func apply(_ image: CIImage, grade: EffectGrade) -> CIImage {
        let lut = { (input: CIImage) in ColorGrader.lut(input, name: grade.lutName) }
        switch grade.recipe {
        case .dazzFisheyeWide:
            return aberration(lut(image), blurAt2048: 10)
        case .dazzFisheyeFull:
            return aberration(lut(image), blurAt2048: 8.5)
        case .dazzLightLeak:
            return lightLeak(lut(image))
        case .kapiDarkCorner:
            return softLightCorner(lut(image), alpha: 0.2)
        case .kapiXT30:
            return multiplyCorner(softLightCorner(lut(image), alpha: 0.25), alpha: 0.25)
        case .kapiDV:
            return dvGlow(lut(image))
        case .kapiCCD:
            return ccdGlow(GradeApplicator.mix(image, lut(image), amount: 0.7))
        case .kapiOldPhone:
            return oldPhone(image, lut: lut)
        case .kapiLomo:
            return lomo(image, lut: lut)
        case .kapiNN:
            return softFocus(GradeApplicator.mix(image, lut(image), amount: 0.649), sigmaAt1080: 1.7, amount: 0.303)
        case .kapiFino:
            return softFocus(lut(image), sigmaAt1080: 1.24, amount: 0.46)
        case .halideValencia:
            return lut(halideFilm(image, gains: (0.2, 0.1, 0.05), halationRadius: 1, mtfFrequency: 0.5))
        case .halideNova:
            return lut(halideFilm(image, gains: (0.6, 0.3, 0.1), halationRadius: 1, mtfFrequency: 0.5))
        case .halideScarlet:
            return lut(halideFilm(image, gains: (0.25, 0.1, 0.05), halationRadius: 7, mtfFrequency: 1.5))
        case .halideNoir:
            return lut(halideFilm(image, gains: (0.2, 0.2, 0.2), halationRadius: 1, mtfFrequency: 0.5))
        case .lampaAutoLevels:
            return lut(AutoLevels.apply(image))
        case .moodCrush:
            return lut(moodTone(image, contrast: 1.3, postExposure: -0.1, mute: 0, saturation: 1))
        case .moodFaded:
            return lut(moodTone(image, contrast: 1.1, postExposure: 0, mute: 0.15, saturation: 0.85))
        case .moodExpired:
            return lut(moodTone(image, contrast: 0.9, postExposure: -0.05, mute: 0.08, saturation: 0.85))
        case .nomoAnalog:
            return lut(exposure(image, ev: 0.33))
        case .nomoHardBW:
            return lut(image.applyingFilter("CIPhotoEffectNoir").cropped(to: image.extent))
        case .noFusionBloom:
            return lut(bloom(image))
        }
    }

    // MARK: - Dazz

    /// Dazz `fishEye`, factor = 1.69 × diagonal × (1 − p). W uses p 0.55, F uses 0.68.
    private static func fisheye(_ image: CIImage, radius p: CGFloat, over frame: CGRect? = nil) -> CIImage {
        let extent = frame ?? image.extent
        guard let kernel = EffectKernels.fisheye, extent.width > 1 else { return image }
        let source = frame == nil ? image.clampedToExtent() : image
        let factor = 1.69 * hypot(extent.width, extent.height) * (1 - p)
        let reach = extent.insetBy(dx: -extent.width * 2, dy: -extent.height * 2)
        return kernel.apply(
            extent: extent,
            roiCallback: { _, _ in reach },
            image: source,
            arguments: [CIVector(x: extent.midX, y: extent.midY), factor]
        ) ?? image
    }

    /// F shrinks the photo to 0.87 around the center on black before bending it.
    private static func prescaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        let extent = image.extent
        let transform = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
        return image.transformed(by: transform).composited(over: CIImage(color: .black))
    }

    /// Dazz draws F's round edge with its own frame and mask images. This circle stands in for them:
    /// radius 0.617 of the width, measured on a Dazz F photo, with a soft edge of 4% of the width.
    private static func circleMask(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let radius = extent.width * 0.617
        let mask = CIImage.radialGradient(
            center: CGPoint(x: extent.midX, y: extent.midY),
            inner: radius - extent.width * 0.04,
            outer: radius,
            from: .white,
            to: .black,
            extent: extent
        )
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: extent),
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
    }

    /// Dazz `AberrationFilter`: s = min(W, H) / 2048, blur = s > 10 ? b : b × s, 5 samples.
    private static func aberration(_ image: CIImage, blurAt2048 base: CGFloat) -> CIImage {
        let extent = image.extent
        guard let kernel = EffectKernels.aberration, extent.width > 1 else { return image }
        let s = min(extent.width, extent.height) / 2048
        let blur = s > 10 ? base : base * s
        let margin = blur * 2 + 2
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -margin, dy: -margin) },
            arguments: [
                image.clampedToExtent(),
                CIVector(x: extent.midX, y: extent.midY),
                hypot(extent.width, extent.height) / 2,
                blur,
                5
            ]
        )?.cropped(to: extent) ?? image
    }

    /// Dazz screens a warm leak image over the photo. The leak images are Dazz's own, so this is a
    /// warm gradient from the top-right corner; its color, size, and opacity are ours.
    private static func lightLeak(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let leak = CIImage.radialGradient(
            center: CGPoint(x: extent.maxX - extent.width * 0.08, y: extent.maxY - extent.height * 0.1),
            inner: 0,
            outer: extent.width * 0.8,
            from: CIColor(red: 1, green: 0.42, blue: 0.12),
            to: .black,
            extent: extent
        )
        return GradeApplicator.mix(image, screen(leak, over: image), amount: 0.7)
    }

    // MARK: - KAPI

    /// KAPI loads corner images per aspect. These gradients stand in: neutral in the middle, dark at the corners.
    private static func corner(_ extent: CGRect, middle: CGFloat, edge: CGFloat) -> CIImage {
        let half = hypot(extent.width, extent.height) / 2
        return CIImage.radialGradient(
            center: CGPoint(x: extent.midX, y: extent.midY),
            inner: half * 0.45,
            outer: half,
            from: CIColor(red: middle, green: middle, blue: middle),
            to: CIColor(red: edge, green: edge, blue: edge),
            extent: extent
        )
    }

    private static func softLightCorner(_ image: CIImage, alpha: Float) -> CIImage {
        guard let kernel = EffectKernels.softLight else { return image }
        let texture = corner(image.extent, middle: 0.5, edge: 0.12)
        return kernel.apply(extent: image.extent, arguments: [image, texture, alpha]) ?? image
    }

    private static func multiplyCorner(_ image: CIImage, alpha: Float, edge: CGFloat = 0.35) -> CIImage {
        guard let kernel = EffectKernels.multiply else { return image }
        let texture = corner(image.extent, middle: 1, edge: edge)
        return kernel.apply(extent: image.extent, arguments: [image, texture, alpha]) ?? image
    }

    /// KAPI 5S: highlights at 0.25 size (0.3, 0.99, ×1.8), four blurs, bloom 0.2, color noise 0.1,
    /// then 0.4-size motion blur mixed 0.48. Gray noise 0.65 is the catalog grain.
    private static func dvGlow(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard let brightPass = EffectKernels.brightPass else { return image }
        let small = shrunk(image, by: 0.25)
        guard let bright = brightPass.apply(extent: small.extent, arguments: [small, 0.3, 0.99, 1.8]) else { return image }
        let glow = grown(blurred(bright, sigma: extent.width * 0.019 * 0.25), by: 0.25, to: extent)
        let scaledGlow = glow.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.2, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let bloomed = added(scaledGlow, to: image)
        let noisy = GradeApplicator.mix(bloomed, colorNoise(over: bloomed), amount: 0.1)
        let smeared = grown(motionBlurred(shrunk(noisy, by: 0.4), radius: extent.width * 0.005 * 0.4), by: 0.4, to: extent)
        return GradeApplicator.mix(noisy, smeared, amount: 0.48)
    }

    /// KAPI G-CCD: the 0.4-size motion blur twice, screened with itself, mixed 0.4 over the LUT.
    private static func ccdGlow(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let radius = extent.width * 0.008 * 0.4
        let small = motionBlurred(motionBlurred(shrunk(image, by: 0.4), radius: radius), radius: radius)
        let smeared = grown(small, by: 0.4, to: extent)
        return GradeApplicator.mix(image, screen(smeared, over: smeared), amount: 0.4)
    }

    /// KAPI 4S: soft 0.4-size copy, LUT, screened motion blur mixed 0.35, sharpen 0.38.
    private static func oldPhone(_ image: CIImage, lut: (CIImage) -> CIImage) -> CIImage {
        let extent = image.extent
        let soft = grown(blurred(shrunk(image, by: 0.4), sigma: 1.2 * unit1080(extent) * 0.4), by: 0.4, to: extent)
        let colored = lut(soft)
        let radius = extent.width * 0.006 * 0.4
        let smeared = grown(motionBlurred(motionBlurred(shrunk(colored, by: 0.4), radius: radius), radius: radius), by: 0.4, to: extent)
        let glowed = GradeApplicator.mix(colored, screen(smeared, over: smeared), amount: 0.35)
        return glowed.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: 2 * unit1080(extent),
            kCIInputIntensityKey: 0.38
        ]).cropped(to: extent)
    }

    /// KAPI LOMO: dark layer 0.5, light layer 0.32, LUT, 5-tap blur mixed 0.5.
    private static func lomo(_ image: CIImage, lut: (CIImage) -> CIImage) -> CIImage {
        let extent = image.extent
        let dark = multiplyCorner(image, alpha: 0.5, edge: 0.25)
        let light = CIImage.radialGradient(
            center: CGPoint(x: extent.midX, y: extent.midY),
            inner: 0,
            outer: hypot(extent.width, extent.height) * 0.35,
            from: CIColor(red: 1, green: 0.95, blue: 0.85),
            to: .black,
            extent: extent
        )
        let lit = GradeApplicator.mix(dark, screen(light, over: dark), amount: 0.32)
        let colored = lut(lit)
        return GradeApplicator.mix(colored, blurred(colored, sigma: 2.2 * unit1080(extent)), amount: 0.5)
    }

    /// KAPI NN and FiNO35: a small Gaussian at KAPI's 1080 base width, mixed back at a fixed opacity.
    private static func softFocus(_ image: CIImage, sigmaAt1080: CGFloat, amount: Float) -> CIImage {
        GradeApplicator.mix(image, blurred(image, sigma: sigmaAt1080 * unit1080(image.extent)), amount: amount)
    }

    // MARK: - Halide

    /// Halide Photo Final before its LUT: MTF, then halation. Its pixel sizes are on the full still, taken as 4032 wide.
    private static func halideFilm(
        _ image: CIImage,
        gains: (CGFloat, CGFloat, CGFloat),
        halationRadius: CGFloat,
        mtfFrequency: CGFloat
    ) -> CIImage {
        let scale = image.extent.width / 4032
        let sharpened = mtf(image, frequency: mtfFrequency * scale, radius: 2 * scale)
        return halation(sharpened, gains: gains, radius: halationRadius)
    }

    /// low = G(x, frequency), result = low + 2 G(x − low, radius). Halide raises linear input to 1/2.2 first;
    /// the working values here are already gamma encoded.
    private static func mtf(_ image: CIImage, frequency: CGFloat, radius: CGFloat) -> CIImage {
        guard let subtract = EffectKernels.subtract, let combine = EffectKernels.mtfCombine else { return image }
        let extent = image.extent
        let low = blurred(image, sigma: frequency)
        guard let residual = subtract.apply(extent: extent, arguments: [image, low]) else { return image }
        let smoothed = blurred(residual, sigma: radius)
        return combine.apply(extent: extent, arguments: [low, smoothed]) ?? image
    }

    /// Trim at 0.25 size, gains, blur with sigma radius × 0.25, grow 4×, add. The trim threshold of 0.75
    /// and the radius unit of 0.4% of the width are ours.
    private static func halation(_ image: CIImage, gains: (CGFloat, CGFloat, CGFloat), radius: CGFloat) -> CIImage {
        let extent = image.extent
        guard let trim = EffectKernels.halationTrim else { return image }
        let small = shrunk(image, by: 0.25)
        guard let over = trim.apply(extent: small.extent, arguments: [small, 0.75]) else { return image }
        let tinted = over.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gains.0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gains.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gains.2, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).applyingFilter("CIColorClamp")
        let sigma = radius * extent.width * 0.004 * 0.25
        let glow = grown(blurred(tinted, sigma: sigma), by: 0.25, to: extent)
        return added(glow, to: image)
    }

    // MARK: - Mood, NOMO, No Fusion

    /// Mood's order: exposure, then color controls, then the film cube. Mute is taken as extra desaturation.
    private static func moodTone(_ image: CIImage, contrast: Float, postExposure: Float, mute: Float, saturation: Float) -> CIImage {
        exposure(image, ev: postExposure).applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: contrast,
            kCIInputSaturationKey: saturation * (1 - mute),
            kCIInputBrightnessKey: 0
        ]).cropped(to: image.extent)
    }

    private static func exposure(_ image: CIImage, ev: Float) -> CIImage {
        guard abs(ev) > 0.001 else { return image }
        return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev]).cropped(to: image.extent)
    }

    /// No Fusion: `CIBloom` before the LUT, radius 10 scaled by size. The 1080 base and intensity 0.5 are ours.
    private static func bloom(_ image: CIImage) -> CIImage {
        image.clampedToExtent().applyingFilter("CIBloom", parameters: [
            kCIInputRadiusKey: 10 * unit1080(image.extent),
            kCIInputIntensityKey: 0.5
        ]).cropped(to: image.extent)
    }

    // MARK: - Helpers

    private static func unit1080(_ extent: CGRect) -> CGFloat {
        max(extent.width, 1) / 1080
    }

    private static func blurred(_ image: CIImage, sigma: CGFloat) -> CIImage {
        guard sigma > 0.05 else { return image }
        return image.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: image.extent)
    }

    private static func motionBlurred(_ image: CIImage, radius: CGFloat) -> CIImage {
        guard radius > 0.05 else { return image }
        return image.clampedToExtent().applyingFilter("CIMotionBlur", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputAngleKey: 0
        ]).cropped(to: image.extent)
    }

    private static func shrunk(_ image: CIImage, by scale: CGFloat) -> CIImage {
        image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func grown(_ small: CIImage, by scale: CGFloat, to extent: CGRect) -> CIImage {
        small.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
    }

    /// `CIAdditionCompositing` also adds alpha, which halves the picture once unpremultiplied.
    private static func added(_ glow: CIImage, to image: CIImage) -> CIImage {
        guard let kernel = EffectKernels.addColor else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, glow]) ?? image
    }

    private static func screen(_ top: CIImage, over bottom: CIImage) -> CIImage {
        top.applyingFilter("CIScreenBlendMode", parameters: [
            kCIInputBackgroundImageKey: bottom
        ]).cropped(to: bottom.extent)
    }

    private static let noise = CIImage.random

    private static func colorNoise(over image: CIImage) -> CIImage {
        noise.cropped(to: image.extent).applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ]).cropped(to: image.extent)
    }
}

private extension CIImage {
    static var random: CIImage {
        CIFilter(name: "CIRandomGenerator")?.outputImage ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
    }

    static func radialGradient(
        center: CGPoint,
        inner: CGFloat,
        outer: CGFloat,
        from: CIColor,
        to: CIColor,
        extent: CGRect
    ) -> CIImage {
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(cgPoint: center),
            "inputRadius0": max(inner, 0),
            "inputRadius1": max(outer, inner + 1),
            "inputColor0": from,
            "inputColor1": to
        ])?.outputImage
        return (gradient ?? CIImage(color: from)).cropped(to: extent)
    }
}
