import CoreImage

/// 模糊 over any look: Core Image's Gaussian blur on the picture before its color. Whole blurs it evenly; 抠人
/// blurs the background and the people each on their own, with the other weighted out so neither's color smears
/// into the other, then lays the people over the background. Blurs scale with the picture, so the preview, a still
/// and a movie frame look alike. 银幕's scene light goes through the same steps.
enum BlurLayer {
    /// The widest blur's sigma, as a share of the picture's shorter side.
    private static let widest: CGFloat = 0.05
    /// The cut-out's edge is softened by this share of the shorter side, so hair doesn't cut out hard.
    private static let edge: CGFloat = 0.003

    /// `people` is white on people, scaled to `image`. Without it 抠人 leaves the picture alone, as in the first
    /// frames before a mask arrives, rather than blur the people too.
    static func apply(_ image: CIImage, scene: CIImage?, people: CIImage?, settings: BlurSettings) -> (CIImage, CIImage?) {
        let extent = image.extent
        let side = min(extent.width, extent.height)
        func sigma(_ amount: Float) -> CGFloat {
            CGFloat(min(max(amount, 0), 1)) * widest * side
        }
        switch settings.mode {
        case .whole:
            let spread = sigma(settings.whole)
            guard spread >= 0.5 else { return (image, scene) }
            return (blurred(image, spread), scene.map { blurred($0, spread) })
        case .people:
            guard let people else { return (image, scene) }
            let mask = people.clampedToExtent().applyingGaussianBlur(sigma: max(edge * side, 1)).cropped(to: extent)
            let behind = sigma(settings.background)
            let front = sigma(settings.people)
            return (cutOut(image, mask: mask, behind: behind, front: front),
                    scene.map { cutOut($0, mask: mask, behind: behind, front: front) })
        }
    }

    private static func blurred(_ image: CIImage, _ sigma: CGFloat) -> CIImage {
        image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
    }

    private static func cutOut(_ image: CIImage, mask: CIImage, behind: CGFloat, front: CGFloat) -> CIImage {
        let extent = image.extent
        guard let out = EffectKernels.peopleOut, let into = EffectKernels.peopleIn, let over = EffectKernels.peopleOver else {
            return image
        }
        func layer(_ kernel: CIColorKernel, _ sigma: CGFloat) -> CIImage {
            guard sigma >= 0.5, let weighted = kernel.apply(extent: extent, arguments: [image, mask]) else { return image }
            return blurred(weighted, sigma)
        }
        return over.apply(extent: extent, arguments: [layer(into, front), layer(out, behind), mask]) ?? image
    }
}
