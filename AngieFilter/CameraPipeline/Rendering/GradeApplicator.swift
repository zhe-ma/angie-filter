import CoreImage
import Foundation

/// Picks the color grader, runs the shared finish, then mixes back toward the original by intensity.
enum GradeApplicator {
    static func apply(_ image: CIImage, look: Look, adjustment: LookAdjustment, quality: RenderQuality) -> CIImage {
        let amount = min(max(adjustment.intensity, 0), 1)
        guard amount > 0.001 else { return image }

        let colored: CIImage
        switch look.grade {
        case .none:
            return image
        case .colorCube(let grade):
            colored = ColorCubeGrader.applyCube(image, name: grade.cubeName)
        case .lutImage(let grade):
            colored = LUTImageGrader.apply(image, grade: grade)
        }

        var graded = FilmFinish.apply(
            colored,
            fade: adjustment.fade,
            shoulder: look.finish.shoulder,
            halation: adjustment.halation,
            skin: look.finish.skin,
            quality: quality
        )
        if let grade = look.grade.colorCube {
            graded = ColorCubeGrader.applySpatial(graded, grade: grade, adjustment: adjustment, quality: quality)
        }
        return mix(image, graded, amount: amount)
    }

    static func mix(_ original: CIImage, _ graded: CIImage, amount: Float) -> CIImage {
        guard amount < 0.999 else { return graded.cropped(to: original.extent) }
        return original.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: graded,
            kCIInputTimeKey: amount
        ]).cropped(to: original.extent)
    }
}
