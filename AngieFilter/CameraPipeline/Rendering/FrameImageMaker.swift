import CoreImage
import CoreVideo

enum FrameImageMaker {
    /// Live preview works on a shorter edge so the color steps stay at display size.
    static let previewMaxLongEdge: CGFloat = 1920

    static func sourceImage(from pixelBuffer: CVPixelBuffer, parameters: RenderParameters) -> CIImage {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(parameters.orientation)
        return prepared(geometry(oriented, parameters: parameters), quality: parameters.quality)
    }

    static func sourceImage(from photoImage: CIImage, parameters: RenderParameters) -> CIImage {
        prepared(geometry(photoImage, parameters: parameters), quality: parameters.quality)
    }

    static func graded(_ source: CIImage, parameters: RenderParameters) -> CIImage {
        let look = LookLibrary.look(id: parameters.lookID)
        return GradeApplicator.apply(
            source,
            look: look,
            adjustment: parameters.adjustment,
            quality: parameters.quality
        )
    }

    /// Upright, optionally mirrored, not yet cropped to an aspect.
    static func upright(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, mirrorHorizontally: Bool) -> CIImage {
        var image = shiftedToOrigin(CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation))
        if mirrorHorizontally {
            image = mirror(image)
        }
        return image
    }

    static func upright(from image: CIImage, orientation: CGImagePropertyOrientation, mirrorHorizontally: Bool) -> CIImage {
        var upright = shiftedToOrigin(image.oriented(orientation))
        if mirrorHorizontally {
            upright = mirror(upright)
        }
        return upright
    }

    static func scaledForPreview(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > previewMaxLongEdge, longEdge > 1 else { return image }
        let scale = previewMaxLongEdge / longEdge
        return shiftedToOrigin(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
    }

    static func thumbnailSource(from image: CIImage, width: CGFloat = 160) -> CIImage {
        let extent = shiftedToOrigin(image).extent
        guard extent.width > 1 else { return image }
        let scale = width / extent.width
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func geometry(_ image: CIImage, parameters: RenderParameters) -> CIImage {
        var upright = shiftedToOrigin(image)
        if parameters.mirrorHorizontally {
            upright = mirror(upright)
        }
        let crop = AspectCrop.pixelRect(for: parameters.aspectRatio, imageExtent: upright.extent)
        return upright.cropped(to: crop)
    }

    private static func prepared(_ image: CIImage, quality: RenderQuality) -> CIImage {
        guard quality == .preview else { return image }
        return scaledForPreview(image)
    }

    private static func mirror(_ image: CIImage) -> CIImage {
        let flipped = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        return shiftedToOrigin(flipped)
    }

    private static func shiftedToOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}
