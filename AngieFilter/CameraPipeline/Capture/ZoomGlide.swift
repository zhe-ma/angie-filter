import QuartzCore

/// 慢推 / 慢拉 / 急推: the zoom goes from where a take starts to where it ends along a curve, then holds.
/// Steps every 1/60 s in log zoom, each step a ramp that lands by the next, so it neither jerks nor strobes in between.
///
/// Touched only on the queue it's started on.
final class ZoomGlide: @unchecked Sendable {
    enum Curve {
        /// Smoothstep: eases in and out, like a dolly on a track.
        case smooth
        /// Exponential ease-out: most of the way in the first moments, then settles, like a snap zoom.
        case snap

        func eased(_ t: Double) -> Double {
            switch self {
            case .smooth: t * t * (3 - 2 * t)
            case .snap: (1 - pow(2, -10 * t)) / (1 - pow(2, -10))
            }
        }
    }

    var onZoom: ((CGFloat, Float) -> Void)?
    var onFinish: (() -> Void)?
    private static let step: Double = 1.0 / 60
    private var timer: DispatchSourceTimer?

    /// Also while it waits to start.
    var isRunning: Bool { timer != nil }

    func start(from: CGFloat, to: CGFloat, over seconds: Double, after delay: Double = 0, curve: Curve = .smooth,
               on queue: DispatchQueue) {
        stop()
        guard from > 0, to > 0, abs(log2(to / from)) > 0.01 else { return }
        let begin = CACurrentMediaTime() + delay
        var last = from
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay + Self.step, repeating: Self.step, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = min(max((CACurrentMediaTime() - begin) / seconds, 0), 1)
            let next = from * pow(to / from, CGFloat(curve.eased(t)))
            let stops = abs(log2(next / last))
            last = next
            if stops > 0 {
                self.onZoom?(next, Float(stops / Self.step))
            }
            if t >= 1 {
                self.stop()
                self.onFinish?()
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
