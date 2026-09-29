import CoreImage
import Foundation

/// 美颜 on the faces of one frame. Before the look, skin luma loses its shallow spots and blotches and some of
/// its shading, so a print's contrast has less to deepen. After the look, skin color is pulled toward the face's
/// average and skin lifts a little toward white.
/// Everything runs inside the faces' box; blur sizes follow the frame's largest face.
struct SkinRetouch {
    private static let maxFaces = 4
    /// Faces narrower than this share of the frame are too small for the retouch to show.
    private static let minFaceWidth: CGFloat = 0.04

    /// Blur sizes as fractions of the face width. Finer than `fineBlur` is pores, and stays.
    private static let maskBlur: CGFloat = 0.03
    private static let fineBlur: CGFloat = 0.003
    private static let midBlur: CGFloat = 0.015
    private static let wideBlur: CGFloat = 0.06
    private static let widestBlur: CGFloat = 0.2
    private static let chromaBlur: CGFloat = 0.15
    /// Band swings under about these, in display luma, are spots and blotches; eyelids and nostrils swing more.
    private static let spotThreshold: Float = 0.05
    private static let blotchThreshold: Float = 0.07
    /// The rest are at full strength, and scale with it. Spots go slower than blotches, so fine texture outlives them.
    private static let spots: Float = 0.6
    private static let blotches: Float = 0.8
    /// Share of the face's broad light and shadow taken out.
    private static let fill: Float = 0.3
    private static let evenness: Float = 0.6
    /// Chroma this far from the face's average, about the gap between skin and lips, is left alone.
    private static let chromaReach: Float = 0.06
    private static let glow: Float = 0.08
    private static let sceneWhite: Float = 12

    private let region: CGRect
    private let faceWidth: CGFloat
    private let mask: CIImage
    private let amount: Float

    /// Nil when `amount` is 0, no face is big enough, or a kernel is missing: the frame is left as it is.
    init?(source: CIImage, faces: [FaceRegion], amount: Float) {
        let amount = min(max(amount, 0), 1)
        guard amount > 0.001 else { return nil }
        self.amount = amount
        let extent = source.extent
        let kept = faces
            .filter { $0.bounds.width >= Self.minFaceWidth }
            .sorted { $0.bounds.width > $1.bounds.width }
            .prefix(Self.maxFaces)
        guard !kept.isEmpty, extent.width > 1, let kernel = EffectKernels.skinMask else { return nil }

        var vectors: [CIVector] = []
        var rolls: [CGFloat] = []
        var box = CGRect.null
        for face in kept {
            let ellipse = face.ellipse(in: extent)
            vectors.append(CIVector(x: ellipse.center.x, y: ellipse.center.y, z: ellipse.radii.width, w: ellipse.radii.height))
            rolls.append(face.roll)
            let reach = max(ellipse.radii.width, ellipse.radii.height)
            box = box.union(CGRect(x: ellipse.center.x - reach, y: ellipse.center.y - reach, width: reach * 2, height: reach * 2))
        }
        while vectors.count < Self.maxFaces {
            vectors.append(CIVector(x: 0, y: 0, z: 0, w: 0))
            rolls.append(0)
        }
        let region = box.intersection(extent).integral
        guard !region.isEmpty else { return nil }
        self.region = region
        faceWidth = (kept.first?.bounds.width ?? 0) * extent.width

        let blurred = Self.blurred(source, in: region, sigma: faceWidth * Self.maskBlur)
        guard let mask = kernel.apply(
            extent: region,
            arguments: [blurred] + vectors + [CIVector(x: rolls[0], y: rolls[1], z: rolls[2], w: rolls[3])]
        ) else { return nil }
        self.mask = mask
    }

    /// Before the look.
    func smoothed(_ image: CIImage) -> CIImage {
        guard let kernel = EffectKernels.skinSmooth else { return image }
        let fine = Self.blurred(image, in: region, sigma: faceWidth * Self.fineBlur)
        let mid = Self.blurred(fine, in: region, sigma: Self.step(from: Self.fineBlur, to: Self.midBlur, width: faceWidth))
        let wide = Self.blurred(mid, in: region, sigma: Self.step(from: Self.midBlur, to: Self.wideBlur, width: faceWidth))
        let widest = Self.blurred(wide, in: region, sigma: Self.step(from: Self.wideBlur, to: Self.widestBlur, width: faceWidth))
        guard let result = kernel.apply(extent: region, arguments: [
            image.cropped(to: region), fine, mid, wide, widest, mask,
            Self.spotThreshold, Self.blotchThreshold, Self.spots * amount, Self.blotches * amount, Self.fill * amount
        ]) else { return image }
        return result.composited(over: image).cropped(to: image.extent)
    }

    /// The same smoothing carried into scene light, for a 银幕 look that prints from the scene.
    func relit(_ scene: CIImage, display: CIImage, smoothed: CIImage) -> CIImage {
        guard let kernel = EffectKernels.skinRelight,
              let result = kernel.apply(extent: region, arguments: [
                  scene.cropped(to: region), display.cropped(to: region), smoothed.cropped(to: region), Self.sceneWhite
              ]) else { return scene }
        return result.composited(over: scene).cropped(to: scene.extent)
    }

    /// After the look.
    func finished(_ image: CIImage) -> CIImage {
        guard let pack = EffectKernels.skinChromaPack, let finish = EffectKernels.skinFinish,
              let packed = pack.apply(extent: region, arguments: [image.cropped(to: region), mask]) else { return image }
        let average = Self.blurred(packed, in: region, sigma: faceWidth * Self.chromaBlur)
        guard let result = finish.apply(extent: region, arguments: [
            image.cropped(to: region), average, mask, Self.evenness * amount, Self.chromaReach, Self.glow * amount
        ]) else { return image }
        return result.composited(over: image).cropped(to: image.extent)
    }

    /// The extra blur that takes an image blurred at `from` to `to`: Gaussian widths add in squares.
    private static func step(from: CGFloat, to: CGFloat, width: CGFloat) -> CGFloat {
        (to * to - from * from).squareRoot() * width
    }

    private static func blurred(_ image: CIImage, in region: CGRect, sigma: CGFloat) -> CIImage {
        image.cropped(to: region).clampedToExtent().applyingGaussianBlur(sigma: max(sigma, 0.5)).cropped(to: region)
    }
}
