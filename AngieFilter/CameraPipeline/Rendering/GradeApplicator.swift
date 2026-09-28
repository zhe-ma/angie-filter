import CoreImage
import Foundation

/// Color, then the shared finish, then a mix back toward the original by intensity.
enum GradeApplicator {
    static func apply(_ image: CIImage, look: Look, adjustment: LookAdjustment, quality: RenderQuality) -> CIImage {
        if case .none = look.grade { return image }
        let amount = min(max(adjustment.intensity, 0), 1)
        guard amount > 0.001 else { return image }

        let colored = ColorGrader.apply(image, grade: look.grade)
        let finished = FilmFinish.apply(
            colored,
            adjustment: adjustment,
            grainPlate: look.finish.grainPlate,
            quality: quality
        )
        return mix(image, finished, amount: amount)
    }

    static func mix(_ original: CIImage, _ graded: CIImage, amount: Float) -> CIImage {
        guard amount < 0.999 else { return graded.cropped(to: original.extent) }
        return original.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: graded,
            kCIInputTimeKey: amount
        ]).cropped(to: original.extent)
    }
}
