import CoreImage
import CoreVideo
import QuartzCore
import Vision

/// Where the people are, for 运镜's 虚化 and the 模糊 look's 抠人. Like `FaceTracker`, the video queue offers every frame and gets the latest
/// mask at once; segmentation runs on a small copy off the video queue whenever the last one is done, at the
/// balanced quality, which keeps up with walking at about 15 a second. A mask older than `stale` is dropped rather
/// than blur a person who has moved on.
final class PersonMask: @unchecked Sendable {
    private static let stale: CFTimeInterval = 0.5

    private struct State {
        var mask: CIImage?
        var made: CFTimeInterval = 0
        var busy = false
        var generation = 0
    }

    private let state = Locked(State())
    private let queue = DispatchQueue(label: "angie.segment", qos: .userInitiated)

    func reset() {
        state.with { $0 = State(generation: $0.generation + 1) }
    }

    /// Call on the video queue. The latest mask, white on people, scaled to `image`'s extent.
    func mask(offering image: CIImage) -> CIImage? {
        let now = CACurrentMediaTime()
        let (mask, generation) = state.with { state -> (CIImage?, Int?) in
            let fresh = now - state.made < Self.stale ? state.mask : nil
            guard !state.busy else { return (fresh, nil) }
            state.busy = true
            return (fresh, state.generation)
        }
        if let generation {
            if let copy = FaceTracker.copy(image) {
                queue.async { [weak self] in
                    self?.segment(copy, generation: generation)
                }
            } else {
                state.with { $0.busy = false }
            }
        }
        guard let mask else { return nil }
        let extent = image.extent
        return mask
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// For a still or a Live Photo frame: segments at once on the calling queue. `accurate` for a still, where the
    /// hair's edge shows; balanced for a movie's many frames. White on people, scaled to `image`'s extent.
    static func mask(in image: CIImage, accurate: Bool) -> CIImage? {
        guard let buffer = copy(image, longEdge: accurate ? 2048 : 768),
              let mask = segmented(buffer, quality: accurate ? .accurate : .balanced) else { return nil }
        let extent = image.extent
        return mask
            .transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
    ])

    private static func copy(_ image: CIImage, longEdge: CGFloat) -> CVPixelBuffer? {
        let extent = image.extent
        let long = max(extent.width, extent.height)
        guard long > 1 else { return nil }
        let scale = min(1, longEdge / long)
        let width = max(Int((extent.width * scale).rounded()), 1)
        let height = max(Int((extent.height * scale).rounded()), 1)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(small, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }

    private static func segmented(_ buffer: CVPixelBuffer, quality: VNGeneratePersonSegmentationRequest.QualityLevel) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        } catch {
            return nil
        }
        return request.results?.first.map { CIImage(cvPixelBuffer: $0.pixelBuffer) }
    }

    private func segment(_ buffer: CVPixelBuffer, generation: Int) {
        let mask = Self.segmented(buffer, quality: .balanced)
        state.with { state in
            guard state.generation == generation else { return }
            state.busy = false
            if let mask {
                state.mask = mask
                state.made = CACurrentMediaTime()
            }
        }
    }
}
