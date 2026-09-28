import CoreImage
import Metal
import MetalKit
import UIKit

final class PreviewMetalView: MTKView {
    private let drawerLock = NSLock()
    private var drawer = 0
    private var context: CIContext?
    private let commandQueue: MTLCommandQueue?

    init(device: MTLDevice) {
        commandQueue = device.makeCommandQueue()
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = false
        colorPixelFormat = .bgra8Unorm
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
        ])
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Invalidates draws from a session that has handed the preview to the other one.
    func claimDrawer() -> Int {
        drawerLock.lock()
        drawer += 1
        let token = drawer
        drawerLock.unlock()
        return token
    }

    func draw(image: CIImage, token: Int) {
        drawerLock.lock()
        let current = drawer
        drawerLock.unlock()
        guard token == current else { return }
        guard bounds.width > 1, bounds.height > 1,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let context else { return }

        let destination = CGRect(origin: .zero, size: drawableSize)
        let fitted = Self.aspectFill(image, in: destination.size)
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        context.render(
            fitted,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: destination,
            colorSpace: colorSpace
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func makeImage(_ image: CIImage) -> UIImage? {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1, let context,
              let cgImage = context.createCGImage(image, from: extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func aspectFill(_ image: CIImage, in pixelSize: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1, pixelSize.width > 1, pixelSize.height > 1 else { return image }
        let scale = max(pixelSize.width / extent.width, pixelSize.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: (pixelSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x,
            y: (pixelSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        ))
        return translated.cropped(to: CGRect(origin: .zero, size: pixelSize))
    }
}
