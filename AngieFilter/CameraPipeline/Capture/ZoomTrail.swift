import AVFoundation
import QuartzCore

/// The zoom a frame was shot at, and how fast it was changing then. Readings are taken as frames come in and looked
/// up at a frame's own presentation time: the newest reading runs ahead of the picture while the zoom moves, and
/// stabilization holds frames back further.
final class ZoomTrail: @unchecked Sendable {
    /// Seconds of readings kept; covers the stabilizer holding frames back.
    private static let history: Double = 1.5
    /// Span the speed is measured over, about two frames.
    private static let span: Double = 0.06

    private struct State {
        var device: AVCaptureDevice?
        var readings: [(time: Double, zoom: CGFloat)] = []
    }

    private let state = Locked(State())

    var isOn: Bool {
        state.with { $0.device != nil }
    }

    func start(_ device: AVCaptureDevice) {
        state.with { $0 = State(device: device) }
    }

    func stop() {
        state.with { $0 = State() }
    }

    /// Call on the video queue with every frame.
    func noteFrame() {
        let now = CACurrentMediaTime()
        state.with { state in
            guard let device = state.device else { return }
            state.readings.append((now, device.videoZoomFactor))
            if let kept = state.readings.firstIndex(where: { $0.time >= now - Self.history }), kept > 0 {
                state.readings.removeFirst(kept)
            }
        }
    }

    /// Between the readings around `time`, on the host clock.
    func zoom(at time: Double) -> CGFloat {
        state.with { Self.zoom(at: time, in: $0.readings) }
    }

    /// Powers of two a second at `time`, positive zooming in; nil before there are readings to tell.
    func stopsPerSecond(at time: Double) -> Double? {
        state.with { state in
            guard let first = state.readings.first, time - Self.span >= first.time else { return nil }
            let now = Self.zoom(at: time, in: state.readings)
            let before = Self.zoom(at: time - Self.span, in: state.readings)
            guard now > 0, before > 0 else { return nil }
            return Double(log2(now / before)) / Self.span
        }
    }

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
