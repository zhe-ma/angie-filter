import AVFoundation
import CoreImage
import QuartzCore

/// 希区柯克变焦: the zoom follows the distance to a face, so the face keeps its size while the phone moves toward it
/// or away and the background stretches or shrinks behind it. A face's size in the frame goes as zoom over distance,
/// so the zoom a frame was shot at over the face's size there is the distance, up to a constant, whatever the zoom
/// did meanwhile. DollyCam feeds the zoomed size straight in and ends up short of holding the face.
/// Every frame the detector is free for is measured; an alpha-beta filter on log distance smooths Vision's wobble
/// and tracks a steady walk without lagging behind it. Armed for a take, the zoom only goes the way the walk does,
/// so what wobble is left can't pump it back and forth.
final class DollyZoom: @unchecked Sendable {
    /// On the detection queue: the zoom to ramp to and the rate, in powers of two per second.
    var onZoom: ((CGFloat, Float) -> Void)?

    /// Share of a measurement's surprise taken into the distance, and into its speed.
    private static let alpha: Double = 0.4
    private static let beta: Double = 0.06
    /// A surprise over this, in natural log, is a turned head or a bad box more than a step; it counts a quarter.
    private static let outlier: Double = 0.15
    /// Ahead of the last measurement, for detection and the zoom taking effect.
    private static let lead: Double = 0.1
    /// Without a face this long the walk is taken to have stopped.
    private static let lostAfter: Double = 0.4
    private static let baselineSamples = 3
    private static let smallestFace: CGFloat = 0.03
    /// Steps smaller than this, in stops, are left out.
    private static let deadBand: CGFloat = 0.003
    /// A face farther than this from the followed one, in frame widths, is someone else.
    private static let reach: CGFloat = 0.25
    /// Zoom readings kept to look up what a frame was shot at.
    private static let history = 12

    private struct Filter {
        var distance: Double
        var speed: Double = 0
        var time: Double
    }

    private struct State {
        var generation = 0
        var device: AVCaptureDevice?
        var range: ClosedRange<CGFloat> = 1...1
        var direction = DollyDirection.away
        var busy = false
        var face: CGRect?
        var extent: CGSize = .zero
        var zooms: [(time: Double, zoom: CGFloat)] = []
        var samples: [Double] = []
        var baseline: (zoom: CGFloat, distance: Double)?
        var filter: Filter?
        var zoom: CGFloat = 1
        var lastLog: Double = 0
    }

    private let state = Locked(State())
    private let queue = DispatchQueue(label: "angie.dolly", qos: .userInteractive)

    var isArmed: Bool {
        state.with { $0.device != nil }
    }

    /// The face's size at the next few detections is the size kept. `range` is one lens's, so the picture never jumps.
    func arm(device: AVCaptureDevice, range: ClosedRange<CGFloat>, direction: DollyDirection) {
        state.with { state in
            state = State(generation: state.generation + 1, device: device, range: range, direction: direction, face: state.face)
            state.zoom = device.videoZoomFactor
        }
    }

    func disarm() {
        state.with { state in
            state = State(generation: state.generation + 1)
        }
    }

    /// Call on the video queue with every frame the preview shows, at its presentation time.
    func offer(_ image: CIImage, at time: CMTime) {
        let now = CACurrentMediaTime()
        let job = state.with { state -> (device: AVCaptureDevice, generation: Int)? in
            guard let device = state.device else { return nil }
            state.zooms.append((now, device.videoZoomFactor))
            if state.zooms.count > Self.history {
                state.zooms.removeFirst(state.zooms.count - Self.history)
            }
            guard !state.busy else { return nil }
            state.busy = true
            return (device, state.generation)
        }
        guard let job else { return }
        let shot = time.isValid ? time.seconds : now
        let extent = image.extent.size
        guard let copy = FaceTracker.copy(image) else {
            state.with { $0.busy = false }
            return
        }
        queue.async { [weak self] in
            self?.update(FaceTracker.detect(copy), shot: shot, extent: extent, generation: job.generation)
        }
    }

    private func update(_ faces: [FaceRegion], shot: Double, extent: CGSize, generation: Int) {
        let step = state.with { state -> (zoom: CGFloat, rate: Float)? in
            guard state.generation == generation else { return nil }
            state.busy = false
            if state.extent != extent {
                // A new aspect measures faces against another frame.
                state.extent = extent
                state.samples = []
                state.baseline = nil
                state.filter = nil
            }
            guard let face = Self.pick(faces.map(\.bounds), near: state.face) else { return nil }
            state.face = face
            let size = (face.width * face.height).squareRoot()
            guard size > Self.smallestFace else { return nil }
            let measured = log(Double(Self.zoom(at: shot, in: state.zooms) / size))
            guard let baseline = state.baseline, var filter = state.filter else {
                state.samples.append(measured)
                if state.samples.count >= Self.baselineSamples {
                    let distance = state.samples.reduce(0, +) / Double(state.samples.count)
                    state.baseline = (state.zoom, distance)
                    state.filter = Filter(distance: distance, time: shot)
                    PerfLog.line(String(format: "dolly baseline zoom %.2f face %.3f", state.zoom, size))
                }
                return nil
            }
            let elapsed = shot - filter.time
            guard elapsed > 0.001 else { return nil }
            if elapsed > Self.lostAfter {
                filter.speed = 0
            }
            let predicted = filter.distance + filter.speed * elapsed
            let surprise = measured - predicted
            let weight = abs(surprise) > Self.outlier ? 0.25 : 1
            filter.distance = predicted + Self.alpha * weight * surprise
            filter.speed += Self.beta * weight * surprise / min(elapsed, Self.lostAfter)
            filter.time = shot
            state.filter = filter
            let ahead = filter.distance + filter.speed * Self.lead - baseline.distance
            let wanted = baseline.zoom * CGFloat(exp(ahead))
            let bounded = min(max(wanted, state.range.lowerBound), state.range.upperBound)
            let target = state.direction == .away ? max(bounded, state.zoom) : min(bounded, state.zoom)
            if shot - state.lastLog >= 1 {
                state.lastLog = shot
                PerfLog.line(String(format: "dolly face %.3f, distance x%.2f, speed %+.2f/s, zoom %.2f -> %.2f",
                                    size, exp(filter.distance - baseline.distance), filter.speed, state.zoom, target))
            }
            let stops = log2(target / state.zoom)
            guard abs(stops) >= Self.deadBand else { return nil }
            state.zoom = target
            // Arrives about when the next measurement does.
            return (target, Float(abs(stops) / max(min(elapsed, 0.1), 1.0 / 60)))
        }
        if let step {
            onZoom?(step.zoom, step.rate)
        }
    }

    /// The zoom at the frame's own time, between the readings taken as frames came in.
    private static func zoom(at time: Double, in readings: [(time: Double, zoom: CGFloat)]) -> CGFloat {
        guard let first = readings.first, let last = readings.last else { return 1 }
        if time <= first.time { return first.zoom }
        if time >= last.time { return last.zoom }
        for (earlier, later) in zip(readings, readings.dropFirst()) where later.time >= time {
            let share = CGFloat((time - earlier.time) / max(later.time - earlier.time, 0.0001))
            return earlier.zoom + share * (later.zoom - earlier.zoom)
        }
        return last.zoom
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
