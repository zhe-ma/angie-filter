import CoreImage
import CoreVideo
import QuartzCore
import Vision

/// Where the people are, for 运镜's 虚化. Like `FaceTracker`, the video queue offers every frame and gets the latest
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

    private func segment(_ buffer: CVPixelBuffer, generation: Int) {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var result: CVPixelBuffer?
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
            result = request.results?.first?.pixelBuffer
        } catch {
            result = nil
        }
        let mask = result.map { CIImage(cvPixelBuffer: $0) }
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
