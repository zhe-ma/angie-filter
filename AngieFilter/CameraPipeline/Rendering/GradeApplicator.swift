import CoreImage
import Foundation

/// Color, then the shared finish, then a mix back toward the original by intensity.
enum GradeApplicator {
    /// `scene` is the same shot in linear scene light, when there is one. Only 银幕 looks read it.
    static func apply(_ image: CIImage, scene: CIImage? = nil, look: Look, adjustment: LookAdjustment, quality: RenderQuality) -> CIImage {
        if case .none = look.grade { return image }
        let amount = min(max(adjustment.intensity, 0), 1)
        guard amount > 0.001 else { return image }

        if case .screen(let screen) = look.grade {
            let printed = ScreenPrint.apply(
                image,
                scene: scene,
                lutName: screen.imageName,
                adjustment: adjustment,
                grainPlate: look.finish.grainPlate,
                quality: quality
            )
            return mix(image, printed, amount: amount)
        }
        var base = image
        if case .effect(let effect) = look.grade {
            base = EffectChain.lens(image, grade: effect)
        }
        let colored = ColorGrader.apply(base, grade: look.grade, quality: quality)
        let finished = FilmFinish.apply(
            colored,
            adjustment: adjustment,
            grainPlate: look.finish.grainPlate,
            quality: quality
        )
        return mix(base, finished, amount: amount)
    }

    static func mix(_ original: CIImage, _ graded: CIImage, amount: Float) -> CIImage {
        guard amount < 0.999 else { return graded.cropped(to: original.extent) }
        return original.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: graded,
            kCIInputTimeKey: amount
        ]).cropped(to: original.extent)
    }
}
