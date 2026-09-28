import CoreImage
import CoreGraphics

enum DualFrameComposer {
    static let previewLongEdge: CGFloat = 1280

    static func previewCanvas(widthOverHeight: CGFloat) -> CGSize {
        canvasSize(widthOverHeight: widthOverHeight, longEdge: previewLongEdge)
    }

    static func stillCanvas(widthOverHeight: CGFloat, back: CIImage, front: CIImage) -> CGSize {
        let edge = max(back.extent.width, back.extent.height, front.extent.width, front.extent.height)
        let longEdge = min(max(edge, 640), 4032)
        return canvasSize(widthOverHeight: widthOverHeight, longEdge: longEdge)
    }

    static func compose(back: CIImage?, front: CIImage?, settings: DualSettings, canvas: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: canvas)
        guard canvas.width > 1, canvas.height > 1 else {
            return CIImage(color: CIColor.black).cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let geometry = DualFrameGeometry.make(canvas: canvas, settings: settings)
        var output = CIImage(color: CIColor.black).cropped(to: bounds)
        output = place(image(for: geometry.lead.facing, back: back, front: front), pane: geometry.lead, on: output, canvasHeight: canvas.height)
        output = place(image(for: geometry.other.facing, back: back, front: front), pane: geometry.other, on: output, canvasHeight: canvas.height)
        return output.cropped(to: bounds)
    }

    private static func canvasSize(widthOverHeight: CGFloat, longEdge: CGFloat) -> CGSize {
        let edge = max(longEdge, 2).rounded()
        if widthOverHeight >= 1 {
            return CGSize(width: edge, height: max((edge / widthOverHeight).rounded(), 2))
        }
        return CGSize(width: max((edge * widthOverHeight).rounded(), 2), height: edge)
    }

    private static func image(for facing: CameraFacing, back: CIImage?, front: CIImage?) -> CIImage? {
        facing == .front ? front : back
    }

    private static func place(_ image: CIImage?, pane: DualFrameGeometry.Pane, on canvas: CIImage, canvasHeight: CGFloat) -> CIImage {
        guard let image, image.extent.width > 1, image.extent.height > 1, pane.frame.width > 1, pane.frame.height > 1 else {
            return canvas
        }
        let destination = coreImageRect(pane.frame, canvasHeight: canvasHeight)
        var placed = fitted(image, to: destination)
        if pane.opacity < 0.999 {
            placed = faded(placed, alpha: pane.opacity)
        }
        if let mask = mask(for: pane, in: destination) {
            placed = applying(mask: mask, to: placed)
        }
        return placed.composited(over: canvas).cropped(to: canvas.extent)
    }

    private static func fitted(_ image: CIImage, to rect: CGRect) -> CIImage {
        let target = rect.width / max(rect.height, 1)
        let crop = AspectCrop.pixelRect(widthOverHeight: target, imageExtent: image.extent)
        let cropped = image.cropped(to: crop)
        let scale = rect.width / max(cropped.extent.width, 1)
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: rect.minX - scaled.extent.origin.x,
            y: rect.minY - scaled.extent.origin.y
        ))
    }

    private static func faded(_ image: CIImage, alpha: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
        ])
    }

    private static func mask(for pane: DualFrameGeometry.Pane, in rect: CGRect) -> CIImage? {
        switch pane.shape {
        case .rect:
            return nil
        case .circle:
            return circleMask(in: rect)
        case .rounded(let radius):
            return roundedMask(in: rect, radius: radius)
        }
    }

    private static func circleMask(in rect: CGRect) -> CIImage? {
        let radius = min(rect.width, rect.height) / 2
        guard radius > 1, let filter = CIFilter(name: "CIRadialGradient") else { return nil }
        filter.setValue(CIVector(x: rect.midX, y: rect.midY), forKey: "inputCenter")
        filter.setValue(max(radius - 1, 0), forKey: "inputRadius0")
        filter.setValue(radius, forKey: "inputRadius1")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 0), forKey: "inputColor1")
        return filter.outputImage?.cropped(to: rect)
    }

    private static func roundedMask(in rect: CGRect, radius: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CIRoundedRectangleGenerator") else { return nil }
        filter.setValue(CIVector(cgRect: rect), forKey: "inputExtent")
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor")
        return filter.outputImage?.cropped(to: rect)
    }

    private static func applying(mask: CIImage, to image: CIImage) -> CIImage {
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            "inputBackgroundImage": clear,
            "inputMaskImage": mask
        ]).cropped(to: image.extent)
    }

    private static func coreImageRect(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
