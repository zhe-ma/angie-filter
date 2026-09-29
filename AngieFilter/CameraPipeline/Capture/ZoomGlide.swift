import QuartzCore

/// 慢推 / 慢拉: the zoom eases from where a take starts to where it ends over a few seconds, then holds.
/// Steps every 1/30 s in log zoom along a smoothstep, each step a ramp that lands by the next, so it neither jerks at
/// the ends nor strobes in between.
///
/// Touched only on the queue it's started on.
final class ZoomGlide: @unchecked Sendable {
    var onZoom: ((CGFloat, Float) -> Void)?
    var onFinish: (() -> Void)?
    private static let step: Double = 1.0 / 30
    private var timer: DispatchSourceTimer?

    var isRunning: Bool { timer != nil }

    func start(from: CGFloat, to: CGFloat, over seconds: Double, on queue: DispatchQueue) {
        stop()
        guard from > 0, to > 0, abs(log2(to / from)) > 0.01 else { return }
        let begin = CACurrentMediaTime()
        var last = from
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.step, repeating: Self.step, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = min((CACurrentMediaTime() - begin) / seconds, 1)
            let eased = CGFloat(t * t * (3 - 2 * t))
            let next = from * pow(to / from, eased)
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
