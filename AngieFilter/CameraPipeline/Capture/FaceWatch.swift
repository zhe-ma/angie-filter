import CoreImage
import CoreMedia
import QuartzCore

/// The face a 运镜 take follows, measured on every frame the detector is free for. Starts with the largest face and
/// keeps to the one nearest the last; after a while without it, starts over with the largest.
/// Detects on a small copy off the video queue, like `FaceTracker`, since the capture pool stalls on held buffers.
final class FaceWatch: @unchecked Sendable {
    /// On the detection queue: the followed face normalized to the frame, or nil when it isn't there; the frame's
    /// presentation time in seconds; and the frame's size, which the box is normalized to.
    var onSighting: ((CGRect?, Double, CGSize) -> Void)?

    /// A face farther than this from the followed one, in frame widths, is someone else.
    private static let reach: CGFloat = 0.25
    /// Seconds without the followed face before any face will do.
    private static let forgetAfter: Double = 1

    private struct State {
        var generation = 0
        var on = false
        var busy = false
        var face: CGRect?
        var lastSeen: Double = 0
    }

    private let state = Locked(State())
    private let queue = DispatchQueue(label: "angie.follow", qos: .userInteractive)

    var isOn: Bool {
        state.with { $0.on }
    }

    func start() {
        state.with { state in
            state = State(generation: state.generation + 1, on: true)
        }
    }

    func stop() {
        state.with { state in
            state = State(generation: state.generation + 1)
        }
    }

    /// Call on the video queue with every frame, uncut, at its presentation time.
    func offer(_ image: CIImage, at time: CMTime) {
        let generation = state.with { state -> Int? in
            guard state.on, !state.busy else { return nil }
            state.busy = true
            return state.generation
        }
        guard let generation else { return }
        let shot = time.isValid ? time.seconds : CACurrentMediaTime()
        let extent = image.extent.size
        guard let copy = FaceTracker.copy(image) else {
            state.with { $0.busy = false }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let faces = FaceTracker.detect(copy).map(\.bounds)
            let sighting = self.state.with { state -> CGRect?? in
                guard state.generation == generation else { return nil }
                state.busy = false
                let last = shot - state.lastSeen > Self.forgetAfter ? nil : state.face
                let face = Self.pick(faces, near: last)
                if let face {
                    state.face = face
                    state.lastSeen = shot
                }
                return .some(face)
            }
            guard let sighting else { return }
            self.onSighting?(sighting, shot, extent)
        }
    }

    /// The largest face to start; after that the one nearest the last, unless it's gone.
    private static func pick(_ faces: [CGRect], near last: CGRect?) -> CGRect? {
        guard let last else {
            return faces.max { $0.width * $0.height < $1.width * $1.height }
        }
        func gap(_ face: CGRect) -> CGFloat {
            hypot(face.midX - last.midX, face.midY - last.midY)
        }
        guard let nearest = faces.min(by: { gap($0) < gap($1) }), gap(nearest) < reach else { return nil }
        return nearest
    }
}
