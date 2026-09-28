import CoreImage
import QuartzCore

/// Keeps a small bitmap copy of the latest frame for the filter strip.
/// The capture pool has only a few buffers and stops delivering frames when any stay checked out,
/// so nothing outside the live preview may hold a camera-backed `CIImage`.
final class ThumbnailFrameTap: @unchecked Sendable {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
    ])
    private static let interval: CFTimeInterval = 0.5

    private let state = Locked(TapState())

    /// Call on the video queue with every upright, cropped frame. Copies at most twice a second.
    func offer(_ image: CIImage) {
        let due = state.with { state -> Bool in
            let now = CACurrentMediaTime()
            guard now - state.copiedAt >= Self.interval else { return false }
            state.copiedAt = now
            return true
        }
        guard due, let copy = Self.copy(image) else { return }
        state.with { $0.image = copy }
    }

    func latest() -> CIImage? {
        state.with { $0.image }
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

private struct TapState {
    var image: CIImage?
    var copiedAt: CFTimeInterval = 0
}
