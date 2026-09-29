import CoreImage
import CoreMedia
import QuartzCore
import Vision

/// The person a 运镜 take follows, measured on every frame the detector is free for. Starts with the largest face and
/// keeps to the one nearest the last; after a while without it, starts over with the largest. When no face is near,
/// a person's upper body stands in, so a turned back or a profile the face detector misses keeps being followed.
/// A tap picks who or what to follow instead: the face or body there, or else the spot itself, tracked by Vision.
/// Detects on a small copy off the video queue, like `FaceTracker`, since the capture pool stalls on held buffers.
final class FaceWatch: @unchecked Sendable {
    struct Sighting {
        /// Normalized to the frame.
        var box: CGRect
        /// An upper body or a tracked spot rather than a face: its size says nothing about distance.
        var body: Bool
        /// Just picked by a tap: the framing should keep it where it is now.
        var picked = false
    }

    /// On the detection queue: the followed person, or nil when they aren't there; the frame's presentation time in
    /// seconds; and the frame's size, which the box is normalized to.
    var onSighting: ((Sighting?, Double, CGSize) -> Void)?

    /// A face farther than this from the followed one, in frame widths, is someone else.
    private static let reach: CGFloat = 0.25
    /// An upper body's middle sits below the face it follows on from, so it may be farther off.
    private static let bodyReach: CGFloat = 0.35
    /// Seconds without the followed face before any face will do.
    private static let forgetAfter: Double = 1
    /// A tap picks the face or body whose middle is this near, in frame widths; otherwise it tracks the spot.
    private static let pickReach: CGFloat = 0.2
    /// A tracked spot's box, in frame widths, square in the frame.
    private static let trackedSide: CGFloat = 0.2
    private static let trackedConfidence: Float = 0.3

    private struct State {
        var generation = 0
        var on = false
        var busy = false
        var face: CGRect?
        var lastSeen: Double = 0
        /// A tapped spot, normalized to the uncut frame, for the next detection.
        var picked: CGPoint?
    }

    private let state = Locked(State())
    private let queue = DispatchQueue(label: "angie.follow", qos: .userInteractive)
    /// Touched only on `queue`: a tapped spot with no face or body at it, followed by Vision's object tracker.
    private var tracker: (generation: Int, handler: VNSequenceRequestHandler, observation: VNDetectedObjectObservation)?

    var isOn: Bool {
        state.with { $0.on }
    }

    /// A spot picked before the take is kept for it.
    func start() {
        state.with { state in
            state = State(generation: state.generation + 1, on: true, picked: state.picked)
        }
    }

    /// Follows whatever is at `spot`, normalized to the uncut frame, from the next frame it measures.
    func pick(_ spot: CGPoint) {
        state.with { $0.picked = spot }
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
            let (last, picked) = self.state.with { state -> (CGRect?, CGPoint?) in
                defer { state.picked = nil }
                return (shot - state.lastSeen > Self.forgetAfter ? nil : state.face, state.picked)
            }
            if self.tracker?.generation != generation {
                self.tracker = nil
            }
            let sighting: Sighting?
            if let picked {
                sighting = self.choose(at: picked, in: copy, generation: generation)
            } else if self.tracker != nil {
                sighting = self.track(copy)
            } else {
                let faces = FaceTracker.detect(copy).map(\.bounds)
                var found = Self.pick(faces, near: last).map { Sighting(box: $0, body: false) }
                // Only once someone has been followed: a body alone never starts a take's framing.
                if found == nil, let last {
                    found = Self.pick(Self.bodies(in: copy), near: last, reach: Self.bodyReach)
                        .map { Sighting(box: $0, body: true) }
                }
                sighting = found
            }
            let current = self.state.with { state -> Bool in
                guard state.generation == generation else { return false }
                state.busy = false
                if let sighting {
                    state.face = sighting.box
                    state.lastSeen = shot
                }
                return true
            }
            guard current else { return }
            self.onSighting?(sighting, shot, extent)
        }
    }

    /// On `queue`: the face at a tapped spot, else the upper body there, else the spot itself, tracked from now on.
    private func choose(at spot: CGPoint, in buffer: CVPixelBuffer, generation: Int) -> Sighting? {
        tracker = nil
        let near = CGRect(origin: spot, size: .zero)
        if let face = Self.pick(FaceTracker.detect(buffer).map(\.bounds), near: near, reach: Self.pickReach) {
            return Sighting(box: face, body: false, picked: true)
        }
        if let body = Self.pick(Self.bodies(in: buffer), near: near, reach: Self.pickReach) {
            return Sighting(box: body, body: true, picked: true)
        }
        let aspect = CGFloat(CVPixelBufferGetWidth(buffer)) / CGFloat(max(CVPixelBufferGetHeight(buffer), 1))
        let side = Self.trackedSide
        let box = CGRect(x: spot.x - side / 2, y: spot.y - side * aspect / 2, width: side, height: side * aspect)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isEmpty else { return nil }
        tracker = (generation, VNSequenceRequestHandler(), VNDetectedObjectObservation(boundingBox: box))
        return Sighting(box: box, body: true, picked: true)
    }

    /// On `queue`: where the tapped spot went; lets it go once Vision loses confidence in it.
    private func track(_ buffer: CVPixelBuffer) -> Sighting? {
        guard let current = tracker else { return nil }
        let request = VNTrackObjectRequest(detectedObjectObservation: current.observation)
        request.trackingLevel = .fast
        do {
            try current.handler.perform([request], on: buffer)
        } catch {
            tracker = nil
            return nil
        }
        guard let next = request.results?.first as? VNDetectedObjectObservation, next.confidence >= Self.trackedConfidence else {
            tracker = nil
            return nil
        }
        tracker?.observation = next
        return Sighting(box: next.boundingBox, body: true)
    }

    private static func bodies(in buffer: CVPixelBuffer) -> [CGRect] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = true
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).map(\.boundingBox)
    }

    /// The largest box to start; after that the one nearest the last, unless it's gone.
    private static func pick(_ boxes: [CGRect], near last: CGRect?, reach: CGFloat = reach) -> CGRect? {
        guard let last else {
            return boxes.max { $0.width * $0.height < $1.width * $1.height }
        }
        func gap(_ box: CGRect) -> CGFloat {
            hypot(box.midX - last.midX, box.midY - last.midY)
        }
        guard let nearest = boxes.min(by: { gap($0) < gap($1) }), gap(nearest) < reach else { return nil }
        return nearest
    }
}
