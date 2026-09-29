import CoreImage
import QuartzCore

/// The 银幕 looks: scene light goes through a mist filter and the negative's halation, back to display light,
/// then the Vision3 print LUT, then per-frame grain, fade, and vignette.
/// Scene light is a ProRAW still developed linear (`sceneLight(fromLinear:baselineExposure:)`), an Apple Log
/// video frame (`sceneLight(fromAppleLog:)`), or the processed photo expanded the way Tools/BakeScreenLUTs.py bakes against. On the expanded path with
/// mist and halation at zero, the round trip is exact and the LUT sees the photo unchanged.
enum ScreenPrint {
    private static let sceneWhite: Float = 12
    /// 0.18 / expandedReinhard(0.18) for a scene white of 12.
    private static let grayScale: Float = {
        let m: Float = 0.18
        let w2 = sceneWhite * sceneWhite
        let b = 1 - m
        return 0.18 / ((-b + (b * b + 4 * m / w2).squareRoot()) * w2 / 2)
    }()

    /// Share of light a mist filter at full strength moves into its halos, and the halo sizes as fractions of the short side.
    private static let mistShare: Float = 0.35
    private static let mistNear: CGFloat = 0.008
    private static let mistFar: CGFloat = 0.04
    /// Scene light above this, about 2.7 stops over middle gray, reaches the film base.
    private static let halationThreshold: Float = 1.2
    private static let halationGain: Float = 0.4
    private static let halationNear: CGFloat = 0.004
    private static let halationFar: CGFloat = 0.012
    private static let halationTint = CIVector(x: 1, y: 0.3, z: 0.06)
    /// Grain moves to a new place 24 times a second.
    private static let grainRate: Double = 24

    /// On top of the file's baseline exposure. Without local tone mapping the file's own exposure prints
    /// about half a stop darker than the phone's photo and the preview.
    private static let rawExposureStops: Float = 0.5
    private static let rawKnee: Float = 1.2
    private static let rawSlope: Float = 4
    /// On top of the camera's own exposure for Apple Log video.
    private static let logExposureStops: Float = 0
    /// ProRAW and Apple Log are colorimetric; the preview comes from the phone's rendering, which adds color.
    /// At 1.3 the print of the ProRAW sample has the same mean Oklab chroma as the print of Apple's rendering.
    private static let sceneSaturation: Float = 1.3

    static func apply(
        _ image: CIImage,
        scene: CIImage? = nil,
        lutName: String,
        adjustment: LookAdjustment,
        grainPlate: GrainPlateKind,
        quality: RenderQuality
    ) -> CIImage {
        let mist = min(max(adjustment.diffusion, 0), 1)
        let halation = min(max(adjustment.halation, 0), 1)
        var input = image
        if let scene {
            input = compressed(optics(scene, mist: mist, halation: halation)) ?? image
        } else if quality != .thumbnail, mist > 0.001 || halation > 0.001, let expanded = expanded(image) {
            input = compressed(optics(expanded, mist: mist, halation: halation)) ?? image
        }
        let printed = ColorGrader.lut(input, name: lutName, quality: quality)
        var finish = adjustment
        finish.halation = 0
        return FilmFinish.apply(printed, adjustment: finish, grainPlate: grainPlate, quality: quality, grainShift: grainShift())
    }

    /// Scene light from a ProRAW development with no tone curve, no local tone mapping, and baseline exposure 0.
    static func sceneLight(fromLinear image: CIImage, baselineExposure: Float) -> CIImage? {
        let gain = exp2(baselineExposure + rawExposureStops)
        return EffectKernels.screenLinear?.apply(extent: image.extent, arguments: [image, gain, sceneSaturation, rawKnee, rawSlope])
    }

    /// Scene light from an Apple Log frame read with no color management.
    static func sceneLight(fromAppleLog image: CIImage) -> CIImage? {
        EffectKernels.screenAppleLog?.apply(extent: image.extent, arguments: [image, exp2(logExposureStops), sceneSaturation])
    }

    /// Scene light as an ordinary display image: the thumbnails, the intensity mix, and any look other than 银幕 use it.
    /// Its expansion gives the scene back, so a 银幕 print of it matches the print of the scene.
    static func displayLight(fromScene scene: CIImage) -> CIImage? {
        compressed(scene)
    }

    private static func expanded(_ image: CIImage) -> CIImage? {
        EffectKernels.screenExpand?.apply(extent: image.extent, arguments: [image, sceneWhite, grayScale])
    }

    private static func compressed(_ scene: CIImage) -> CIImage? {
        EffectKernels.screenCompress?.apply(extent: scene.extent, arguments: [scene, sceneWhite, grayScale])
    }

    private static func optics(_ scene: CIImage, mist: Float, halation: Float) -> CIImage {
        let extent = scene.extent
        let short = min(extent.width, extent.height)
        guard short > 1 else { return scene }
        var lit = scene
        if mist > 0.001, let kernel = EffectKernels.screenMist {
            let near = blurred(lit, sigma: short * mistNear)
            let far = blurred(lit, sigma: short * mistFar)
            lit = kernel.apply(extent: extent, arguments: [lit, near, far, mist * mistShare]) ?? lit
        }
        if halation > 0.001, let bright = EffectKernels.screenBright, let kernel = EffectKernels.screenHalation,
           let source = bright.apply(extent: extent, arguments: [lit, halationThreshold]) {
            let near = blurred(source, sigma: short * halationNear)
            let far = blurred(source, sigma: short * halationFar)
            lit = kernel.apply(extent: extent, arguments: [lit, near, far, halation * halationGain, halationTint]) ?? lit
        }
        return lit
    }

    private static func blurred(_ image: CIImage, sigma: CGFloat) -> CIImage {
        image.clampedToExtent().applyingGaussianBlur(sigma: max(sigma, 0.5)).cropped(to: image.extent)
    }

    /// A new place in the grain tile for every 1/24 s, spread by the golden ratio so neighbours never line up.
    private static func grainShift() -> CGPoint {
        let frame = Double(Int(CACurrentMediaTime() * grainRate))
        let x = (frame * 0.618_034).truncatingRemainder(dividingBy: 1)
        let y = (frame * 0.381_966 + 0.5).truncatingRemainder(dividingBy: 1)
        return CGPoint(x: x, y: y)
    }
}
