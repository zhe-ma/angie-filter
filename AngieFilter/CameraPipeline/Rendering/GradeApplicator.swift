import CoreImage
import Foundation

enum GradeApplicator {
    static func apply(_ image: CIImage, look: Look, intensity: Float, quality: RenderQuality) -> CIImage {
        let amount = min(max(intensity, 0), 1)
        guard amount > 0.001, !look.isOriginal else { return image }

        var graded = applyCube(image, name: look.colorCubeName)
        graded = applyClarity(graded, amount: look.clarity, quality: quality)
        graded = applyGrain(graded, look: look)
        graded = applyVignette(graded, amount: look.vignette, quality: quality)
        return mix(image, graded, amount: amount)
    }

    static func mix(_ original: CIImage, _ graded: CIImage, amount: Float) -> CIImage {
        guard amount < 0.999 else { return graded.cropped(to: original.extent) }
        return original.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: graded,
            kCIInputTimeKey: amount
        ]).cropped(to: original.extent)
    }

    private static func applyCube(_ image: CIImage, name: String?) -> CIImage {
        guard let name,
              let data = ColorCubeStore.shared.data(named: name),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            return image
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(ColorCubeStore.dimension, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.displayP3), forKey: "inputColorSpace")
        filter.setValue(true, forKey: "inputExtrapolate")
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }

    /// Local contrast on luminance only, so the micro-contrast does not fringe color.
    private static func applyClarity(_ image: CIImage, amount: Float, quality: RenderQuality) -> CIImage {
        guard amount > 0.001 else { return image }
        let radius: CGFloat = quality == .preview ? 8 : 18
        let luma = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1,
            kCIInputBrightnessKey: 0
        ]).cropped(to: image.extent)
        let sharp = luma.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount
        ]).cropped(to: image.extent)
        return image.applyingFilter("CIColorBlendMode", parameters: [
            kCIInputBackgroundImageKey: sharp
        ]).cropped(to: image.extent)
    }

    private static func applyGrain(_ image: CIImage, look: Look) -> CIImage {
        guard look.grain > 0.001, let plate = GrainLibrary.image(for: look.grainPlate) else { return image }
        let extent = image.extent
        guard extent.width > 1, plate.extent.width > 1 else { return image }

        let repeats: CGFloat = look.grainPlate == .coarse ? 1.7 : 3
        let scale = (extent.width / repeats) / plate.extent.width
        let tiled = plate
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIAffineTile")
            .cropped(to: extent)
        let soft = tiled.applyingFilter("CISoftLightBlendMode", parameters: [
            kCIInputBackgroundImageKey: image
        ]).cropped(to: extent)
        let mask = midtoneMask(image)
        let masked = soft.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask
        ]).cropped(to: extent)
        return mix(image, masked, amount: look.grain)
    }

    /// Grain stays in the midtones. Deep black and pure white stay clean.
    private static func midtoneMask(_ image: CIImage) -> CIImage {
        let gray = image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1,
            kCIInputBrightnessKey: 0
        ])
        return gray.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.22, y: 0.2),
            "inputPoint2": CIVector(x: 0.5, y: 1),
            "inputPoint3": CIVector(x: 0.78, y: 0.2),
            "inputPoint4": CIVector(x: 1, y: 0)
        ]).cropped(to: image.extent)
    }

    private static func applyVignette(_ image: CIImage, amount: Float, quality: RenderQuality) -> CIImage {
        guard amount > 0.001 else { return image }
        return image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: amount,
            kCIInputRadiusKey: quality == .preview ? 1.2 : 1.6
        ]).cropped(to: image.extent)
    }
}
