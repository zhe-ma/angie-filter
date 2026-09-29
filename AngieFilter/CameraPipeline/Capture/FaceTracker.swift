import CoreImage
import CoreVideo
import QuartzCore
import Vision

/// Finds faces for 美颜. The preview asks with every frame and gets the latest answer at once; a detection runs
/// at most ten times a second, on a small copy of the frame and off the video queue, since the capture pool
/// stalls when a camera buffer stays checked out. A lost face stays for a moment, so a turned head or a missed
/// detection doesn't switch the retouch off and on.
final class FaceTracker: @unchecked Sendable {
    private static let interval: CFTimeInterval = 0.1
    private static let hold: CFTimeInterval = 0.5
    private static let longEdge: CGFloat = 512
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
    ])

    private struct State {
        var faces: [FaceRegion] = []
        var busy = false
        var lastRun: CFTimeInterval = 0
        var lastSeen: CFTimeInterval = 0
    }

    private let state = Locked(State())
    private let queue = DispatchQueue(label: "angie.faces", qos: .userInitiated)

    /// Call on the video queue. Returns the faces from the last detection, normalized to `image`'s extent.
    func faces(offering image: CIImage) -> [FaceRegion] {
        let now = CACurrentMediaTime()
        let (faces, run) = state.with { state -> ([FaceRegion], Bool) in
            let run = !state.busy && now - state.lastRun >= Self.interval
            if run {
                state.busy = true
                state.lastRun = now
            }
            return (state.faces, run)
        }
        guard run else { return faces }
        guard let copy = Self.copy(image) else {
            state.with { $0.busy = false }
            return faces
        }
        queue.async { [weak self] in
            self?.update(Self.detect(copy))
        }
        return faces
    }

    func reset() {
        state.with { $0 = State() }
    }

    /// For a still: detects at once on the calling queue.
    static func detect(in image: CIImage) -> [FaceRegion] {
        copy(image).map(detect) ?? []
    }

    private func update(_ found: [FaceRegion]) {
        let now = CACurrentMediaTime()
        state.with { state in
            state.busy = false
            if found.isEmpty {
                if now - state.lastSeen > Self.hold {
                    state.faces = []
                }
                return
            }
            state.lastSeen = now
            let previous = state.faces
            state.faces = found.map { Self.eased($0, from: previous) }
        }
    }

    /// Halfway from the same face in the last detection, so the retouch doesn't jitter with the detector.
    private static func eased(_ face: FaceRegion, from previous: [FaceRegion]) -> FaceRegion {
        func gap(_ other: FaceRegion) -> CGFloat {
            hypot(other.bounds.midX - face.bounds.midX, other.bounds.midY - face.bounds.midY)
        }
        guard let near = previous.min(by: { gap($0) < gap($1) }), gap(near) < face.bounds.width * 0.5 else { return face }
        let a = near.bounds
        let b = face.bounds
        return FaceRegion(
            bounds: CGRect(x: (a.minX + b.minX) / 2, y: (a.minY + b.minY) / 2, width: (a.width + b.width) / 2, height: (a.height + b.height) / 2),
            roll: (near.roll + face.roll) / 2
        )
    }

    private static func detect(_ buffer: CVPixelBuffer) -> [FaceRegion] {
        let request = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).map {
            FaceRegion(bounds: $0.boundingBox, roll: CGFloat($0.roll?.doubleValue ?? 0))
        }
    }

    /// The frame at detection size in a buffer of its own, with the same framing, so normalized boxes carry over.
    private static func copy(_ image: CIImage) -> CVPixelBuffer? {
        let extent = image.extent
        let long = max(extent.width, extent.height)
        guard long > 1 else { return nil }
        let scale = min(1, longEdge / long)
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = max(Int((extent.width * scale).rounded()), 1)
        let height = max(Int((extent.height * scale).rounded()), 1)
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        context.render(small, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}
