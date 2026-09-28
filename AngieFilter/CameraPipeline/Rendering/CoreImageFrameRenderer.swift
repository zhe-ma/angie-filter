import CoreImage
import Metal
import QuartzCore
import UIKit

/// Draws camera frames into a `CAMetalLayer` from a private queue. The main thread only sets the layer size.
/// One frame is on the GPU at a time; frames that arrive meanwhile keep only the newest.
final class PreviewMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private let commandQueue: MTLCommandQueue?
    private let context: CIContext
    private let renderQueue = DispatchQueue(label: "angie.camera.preview", qos: .userInteractive)
    private let state = Locked(PreviewState())
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
    private let perf = PerfWindow("preview draw")

    private var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    init(device: MTLDevice) {
        commandQueue = device.makeCommandQueue()
        context = CIContext(mtlDevice: device, options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
        ])
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false
        let metalLayer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.colorspace = colorSpace
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
        state.with { $0.size = size }
    }

    /// Invalidates draws from a session that has handed the preview to the other one.
    func claimDrawer() -> Int {
        state.with { state in
            state.drawer += 1
            state.pending = nil
            return state.drawer
        }
    }

    /// Safe from any queue. Never blocks the caller.
    func draw(image: CIImage, token: Int) {
        let start = state.with { state -> Bool in
            guard token == state.drawer else { return false }
            if state.inFlight {
                if state.pending != nil { perf.tally("replaced") }
                state.pending = PendingDraw(image: image, token: token)
                return false
            }
            state.inFlight = true
            return true
        }
        guard start else { return }
        renderQueue.async { [weak self] in
            self?.render(image, token: token)
        }
    }

    func makeImage(_ image: CIImage) -> UIImage? {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1,
              let cgImage = context.createCGImage(image, from: extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func render(_ image: CIImage, token: Int) {
        let size = state.with { state -> CGSize? in
            token == state.drawer ? state.size : nil
        }
        let drawableStart = PerfLog.now()
        guard let size, size.width > 1, size.height > 1,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue?.makeCommandBuffer() else {
            perf.tally("noDrawable")
            finishFrame()
            return
        }
        let waitDrawable = PerfLog.ms(since: drawableStart)
        let encodeStart = PerfLog.now()
        let texture = drawable.texture
        let bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        context.render(
            Self.aspectFill(image, in: bounds.size),
            to: texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: colorSpace
        )
        let encode = PerfLog.ms(since: encodeStart)
        commandBuffer.present(drawable)
        let submitted = PerfLog.now()
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            if let error = buffer.error {
                PerfLog.line("preview command buffer error: \(error)")
                self.perf.tally("gpuError")
            }
            self.perf.add([
                "drawableWait": waitDrawable,
                "encode": encode,
                "gpu": (buffer.gpuEndTime - buffer.gpuStartTime) * 1000,
                "submitToDone": PerfLog.ms(since: submitted)
            ])
            self.finishFrame()
        }
        commandBuffer.commit()
    }

    private func finishFrame() {
        let next = state.with { state -> PendingDraw? in
            guard let pending = state.pending, pending.token == state.drawer else {
                state.pending = nil
                state.inFlight = false
                return nil
            }
            state.pending = nil
            return pending
        }
        guard let next else { return }
        renderQueue.async { [weak self] in
            self?.render(next.image, token: next.token)
        }
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

private struct PreviewState {
    var drawer = 0
    var size = CGSize.zero
    var inFlight = false
    var pending: PendingDraw?
}

private struct PendingDraw {
    var image: CIImage
    var token: Int
}
