import CoreImage

/// Hands the filter strip one bitmap copy of the next frame, only when asked.
/// The capture pool has only a few buffers and stops delivering frames when any stay checked out,
/// so nothing outside the live preview may hold a camera-backed `CIImage`.
final class ThumbnailFrameTap: @unchecked Sendable {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
    ])

    private let waiting = Locked<[@Sendable (CIImage?) -> Void]>([])

    /// The completion runs on the video queue with the next upright, cropped frame.
    func request(_ completion: @escaping @Sendable (CIImage?) -> Void) {
        waiting.with { $0.append(completion) }
    }

    /// Call on the video queue with every frame. Costs one lock unless a request is waiting.
    func offer(_ image: CIImage) {
        let handlers = waiting.with { list -> [@Sendable (CIImage?) -> Void] in
            defer { list.removeAll() }
            return list
        }
        guard !handlers.isEmpty else { return }
        let copy = Self.copy(image)
        handlers.forEach { $0(copy) }
    }

    private static func copy(_ image: CIImage) -> CIImage? {
        let small = FrameImageMaker.thumbnailSource(from: image)
        let origin = small.extent.origin
        let shifted = small.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let extent = shifted.extent.integral
        guard extent.width > 1, extent.height > 1,
              let cgImage = context.createCGImage(shifted, from: extent) else { return nil }
        return CIImage(cgImage: cgImage)
    }
}
