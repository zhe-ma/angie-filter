import CoreImage
import CoreVideo

enum FrameImageMaker {
    /// Live preview works on a shorter edge so the color steps stay at display size.
    static let previewMaxLongEdge: CGFloat = 1920

    static func sourceImage(from pixelBuffer: CVPixelBuffer, parameters: RenderParameters) -> CIImage {
        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(parameters.orientation)
        return prepared(geometry(oriented, parameters: parameters), quality: parameters.quality)
    }

    /// An Apple Log frame as scene light, plus the display image made from it for everything that isn't a 银幕 print.
    /// The frame is read as plain code values: the Log curve is decoded by our own kernel.
    static func logSources(from pixelBuffer: CVPixelBuffer, parameters: RenderParameters) -> (display: CIImage, scene: CIImage)? {
        let codes = CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace: NSNull()]).oriented(parameters.orientation)
        let cut = prepared(geometry(codes, parameters: parameters), quality: parameters.quality)
        guard let scene = ScreenPrint.sceneLight(fromAppleLog: cut),
              let display = ScreenPrint.displayLight(fromScene: scene) else { return nil }
        return (display, scene)
    }

    static func sourceImage(from photoImage: CIImage, parameters: RenderParameters) -> CIImage {
        prepared(geometry(photoImage, parameters: parameters), quality: parameters.quality)
    }

    /// `faces` are normalized to `source`; with 美颜 on they are retouched around the look.
    static func graded(_ source: CIImage, scene: CIImage? = nil, faces: [FaceRegion] = [], parameters: RenderParameters) -> CIImage {
        let look = LookLibrary.look(id: parameters.lookID)
        guard parameters.quality != .thumbnail,
              let retouch = SkinRetouch(source: source, faces: faces, amount: parameters.beauty) else {
            return GradeApplicator.apply(source, scene: scene, look: look, adjustment: parameters.adjustment, quality: parameters.quality)
        }
        let smoothed = retouch.smoothed(source)
        let graded = GradeApplicator.apply(
            smoothed,
            scene: scene.map { retouch.relit($0, display: source, smoothed: smoothed) },
            look: look,
            adjustment: parameters.adjustment,
            quality: parameters.quality
        )
        return retouch.finished(graded)
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

    /// Turns a portrait-upright still so the world's up is up for how the phone was held.
    /// A mirrored selfie turns the same way as the back camera: its preview stays a true mirror
    /// at any angle, so the still only has to undo the phone's rotation.
    static func turned(_ image: CIImage, hold: HoldOrientation) -> CIImage {
        let orientation: CGImagePropertyOrientation
        switch hold {
        case .portrait: return image
        case .landscapeRight: orientation = .right
        case .landscapeLeft: orientation = .left
        case .upsideDown: orientation = .down
        }
        return shiftedToOrigin(image.oriented(orientation))
    }

    /// `cut` of `image`, turned upright and scaled up to fill `image`'s own extent, so the frame keeps its size.
    static func cut(_ image: CIImage, to cut: FrameCut) -> CIImage {
        guard let fill = cut.fill(image.extent) else { return image }
        // Clamped first, so the edges of the cut sample picture rather than transparency.
        return image.clampedToExtent().transformed(by: fill).cropped(to: image.extent)
    }

    /// What's outside `people` (white on them) blurred by up to `radius` pixels, the edge softened so hair doesn't cut
    /// out hard.
    static func backgroundBlurred(_ image: CIImage, people: CIImage, radius: CGFloat) -> CIImage {
        guard radius >= 1 else { return image }
        let background = people
            .applyingFilter("CIColorInvert")
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(radius / 4, 2))
            .cropped(to: image.extent)
        return image.clampedToExtent()
            .applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": background, kCIInputRadiusKey: radius])
            .cropped(to: image.extent)
    }

    /// `amount` of white laid over the picture, for a flash.
    static func flashed(_ image: CIImage, amount: CGFloat) -> CIImage {
        guard amount > 0.001 else { return image }
        let keep = 1 - amount
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: keep, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: keep, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: keep, w: 0),
            "inputBiasVector": CIVector(x: amount, y: amount, z: amount, w: 0)
        ])
    }

    /// The picture moving `length` pixels at `angle` while the shutter was open, as in a fast pan.
    static func motionBlurred(_ image: CIImage, length: CGFloat, angle: CGFloat) -> CIImage {
        guard length >= 2 else { return image }
        return image.clampedToExtent()
            .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: length / 2, kCIInputAngleKey: angle])
            .cropped(to: image.extent)
    }

    /// The zoom moving by `spread` of the frame while the shutter was open, toward `center`; negative zooms out.
    static func zoomBlurred(_ image: CIImage, center: CGPoint, spread: CGFloat) -> CIImage {
        let extent = image.extent
        guard let kernel = EffectKernels.zoomBlur, abs(spread) > 0.0005, extent.width > 1 else { return image }
        let corner = max(hypot(extent.minX - center.x, extent.minY - center.y),
                         hypot(extent.maxX - center.x, extent.maxY - center.y),
                         hypot(extent.minX - center.x, extent.maxY - center.y),
                         hypot(extent.maxX - center.x, extent.minY - center.y))
        // A tap every 3 pixels of the longest streak.
        let samples = min(max(abs(spread) * corner / 3, 4), 48)
        let reach = 1 - spread
        return kernel.apply(
            extent: extent,
            roiCallback: { _, rect in
                let far = CGRect(x: center.x + (rect.minX - center.x) * reach, y: center.y + (rect.minY - center.y) * reach,
                                 width: rect.width * reach, height: rect.height * reach)
                return rect.union(far).insetBy(dx: -2, dy: -2)
            },
            arguments: [image.clampedToExtent(), CIVector(cgPoint: center), spread, samples]
        )?.cropped(to: extent) ?? image
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
