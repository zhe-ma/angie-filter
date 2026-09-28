import CoreImage
import Foundation

/// Places a graded photo on a larger white canvas. The caption bitmap is already rendered.
enum FrameCompositor {
    static func apply(_ image: CIImage, settings: FrameSettings, caption: CIImage?) -> CIImage {
        guard settings.drawsBorder, let layout = FrameLayout.make(photoSize: image.extent.size) else {
            return image
        }
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: canvas)
        let photo = image.transformed(by: CGAffineTransform(
            translationX: layout.photoOrigin.x - image.extent.origin.x,
            y: layout.photoOrigin.y - image.extent.origin.y
        ))
        var framed = photo.composited(over: white).cropped(to: canvas)
        if settings.style == .captioned, let caption {
            let placed = caption.transformed(by: CGAffineTransform(
                translationX: -caption.extent.origin.x,
                y: -caption.extent.origin.y
            ))
            framed = placed.composited(over: framed).cropped(to: canvas)
        }
        return framed
    }
}
