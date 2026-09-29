import AVFoundation
import QuartzCore

/// 希区柯克变焦: the zoom follows the distance to a face, so the face keeps its size while the phone moves toward it
/// or away and the background stretches or shrinks behind it. A face's size in the frame goes as zoom over distance,
/// so the zoom a frame was shot at over the face's size there is the distance, up to a constant, whatever the zoom
/// did meanwhile. DollyCam feeds the zoomed size straight in and ends up short of holding the face.
/// The zoom goes as the distance ratio to a strength's power, so the effect can be softer or stronger than holding.
/// Every sighting from `FaceWatch` is measured; an alpha-beta filter on log distance smooths Vision's wobble
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
    /// Zoom readings kept to look up what a frame was shot at.
    private static let history = 12

    private struct Filter {
        var distance: Double
        var speed: Double = 0
        var time: Double
    }

    private struct State {
        var device: AVCaptureDevice?
        var armedAt: Double = 0
        var range: ClosedRange<CGFloat> = 1...1
        /// Walking away, so the zoom only goes up; otherwise only down.
        var zoomsIn = true
        /// Share of the distance change the zoom makes up: 1 holds the face's size, less lets it grow or shrink some
        /// with the walk, more overshoots so it shrinks as the phone comes closer.
        var strength: Double = 1
        var extent: CGSize = .zero
        var zooms: [(time: Double, zoom: CGFloat)] = []
        var samples: [Double] = []
        var baseline: (zoom: CGFloat, distance: Double)?
        var filter: Filter?
        var zoom: CGFloat = 1
        var lastLog: Double = 0
    }

    private let state = Locked(State())

    var isArmed: Bool {
        state.with { $0.device != nil }
    }

    /// The face's size at the next few sightings is the size kept. `range` is one lens's, so the picture never jumps.
    func arm(device: AVCaptureDevice, range: ClosedRange<CGFloat>, zoomsIn: Bool, strength: Double) {
        state.with { state in
            state = State(device: device, armedAt: CACurrentMediaTime(), range: range, zoomsIn: zoomsIn, strength: strength)
            state.zoom = device.videoZoomFactor
        }
    }

    func disarm() {
        state.with { $0 = State() }
    }

    /// Call on the video queue with every frame, so a sighting can look up the zoom its frame was shot at.
    func noteFrame() {
        let now = CACurrentMediaTime()
        state.with { state in
            guard let device = state.device else { return }
            state.zooms.append((now, device.videoZoomFactor))
            if state.zooms.count > Self.history {
                state.zooms.removeFirst(state.zooms.count - Self.history)
            }
        }
    }

    /// `face` is normalized to a frame of `extent`, shot at `shot` on the host clock.
    func measure(_ face: CGRect?, shot: Double, extent: CGSize) {
        let step = state.with { state -> (zoom: CGFloat, rate: Float)? in
            // A frame from before arming was shot at a zoom the readings no longer cover.
            guard state.device != nil, shot >= state.armedAt else { return nil }
            if state.extent != extent {
                // A new aspect measures faces against another frame.
                state.extent = extent
                state.samples = []
                state.baseline = nil
                state.filter = nil
            }
            guard let face else { return nil }
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
            let wanted = baseline.zoom * CGFloat(exp(ahead * state.strength))
            let bounded = min(max(wanted, state.range.lowerBound), state.range.upperBound)
            let target = state.zoomsIn ? max(bounded, state.zoom) : min(bounded, state.zoom)
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
}
