import CoreImage
import CoreVideo

enum FrameImageMaker {
    static func sourceImage(from pixelBuffer: CVPixelBuffer, parameters: RenderParameters) -> CIImage {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(parameters.orientation)
        return geometry(oriented, parameters: parameters)
    }

    static func sourceImage(from photoImage: CIImage, parameters: RenderParameters) -> CIImage {
        geometry(photoImage, parameters: parameters)
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
