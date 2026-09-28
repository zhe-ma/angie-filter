import CoreImage
import Foundation

/// Picks the grader for `look.grade`, then mixes back toward the original by intensity.
enum GradeApplicator {
    static func apply(_ image: CIImage, look: Look, adjustment: LookAdjustment, quality: RenderQuality) -> CIImage {
        let amount = min(max(adjustment.intensity, 0), 1)
        guard amount > 0.001 else { return image }

        let graded: CIImage
        switch look.grade {
        case .none:
            return image
        case .colorCube(let grade):
            graded = ColorCubeGrader.apply(image, grade: grade, adjustment: adjustment, quality: quality)
        case .lutImage(let grade):
            graded = LUTImageGrader.apply(image, grade: grade)
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
