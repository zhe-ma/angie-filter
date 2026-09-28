import CoreImage
import Foundation

/// Places a graded photo on a larger white canvas. The caption bitmap is already rendered.
enum FrameCompositor {
    static func apply(_ image: CIImage, settings: FrameSettings, caption: CIImage?) -> CIImage {
        guard settings.drawsBorder, let layout = FrameLayout.make(photoSize: image.extent.size, style: settings.style) else {
            return image
        }
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        let photo = image.transformed(by: CGAffineTransform(
            translationX: layout.photoOrigin.x - image.extent.origin.x,
            y: layout.photoOrigin.y - image.extent.origin.y
        ))
        var framed: CIImage
        if settings.style.expandsCanvas {
            let mat = CIImage(color: matColor(settings.style)).cropped(to: canvas)
            framed = photo.composited(over: mat).cropped(to: canvas)
        } else {
            framed = photo.cropped(to: canvas)
        }
        if settings.style == .window {
            framed = windowLine(over: framed, canvas: canvas)
        }
        if settings.allowsCaption, let caption {
            let placed = caption.transformed(by: CGAffineTransform(
                translationX: -caption.extent.origin.x,
                y: -caption.extent.origin.y
            ))
            framed = placed.composited(over: framed).cropped(to: canvas)
        }
        return framed
    }

    private static func matColor(_ style: FrameStyle) -> CIColor {
        if style.isBlack { return CIColor(red: 0, green: 0, blue: 0) }
        if style.isPaper { return CIColor(red: 0.96, green: 0.93, blue: 0.86) }
        return CIColor(red: 1, green: 1, blue: 1)
    }

    /// A hairline rectangle drawn on the photo, inset from the edges.
    private static func windowLine(over image: CIImage, canvas: CGRect) -> CIImage {
        let short = min(canvas.width, canvas.height)
        let inset = (0.04 * short).rounded()
        let thickness = max(2, (0.0035 * short).rounded())
        let inner = canvas.insetBy(dx: inset, dy: inset)
        guard inner.width > thickness * 2, inner.height > thickness * 2 else { return image }
        let color = CIColor(red: 1, green: 1, blue: 1, alpha: 0.92)
        let bars = [
            CGRect(x: inner.minX, y: inner.maxY - thickness, width: inner.width, height: thickness),
            CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: thickness),
            CGRect(x: inner.minX, y: inner.minY, width: thickness, height: inner.height),
            CGRect(x: inner.maxX - thickness, y: inner.minY, width: thickness, height: inner.height)
        ]
        return bars.reduce(image) { partial, rect in
            CIImage(color: color).cropped(to: rect).composited(over: partial)
        }.cropped(to: canvas)
    }
}
