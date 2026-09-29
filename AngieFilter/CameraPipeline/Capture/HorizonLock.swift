import CoreGraphics

/// 锁平 / 匀转 for 运镜: how far to turn the cut against the phone's roll, once a frame on the video queue.
/// The stabilizer already takes the quick shakes out of the roll, so the roll is smoothed about as much first, and
/// only the slow lean left in the picture is turned back: 锁平 to the hold's level, 匀转 to a steady turn that an
/// alpha-beta filter draws through the roll.
final class HorizonLock: @unchecked Sendable {
    /// Seconds for the smoothed roll to cover two thirds of a step, standing in for the stabilizer's own smoothing.
    private static let settle: Double = 0.25
    /// 匀转's share of each frame's surprise taken into the turn's angle, and into its speed: about half a second
    /// to catch up, and a steady turn followed without lag.
    private static let alpha: Double = 0.06
    private static let beta: Double = 0.0019

    private struct State {
        var mode = HorizonMode.off
        var time: Double?
        var roll: Double = 0
        var angle: Double = 0
        var speed: Double = 0
        var tilt: Double = 0
    }

    private let state = Locked(State())

    /// Radians to turn the cut counterclockwise. `hold` is the take's; without one, the hold nearest the roll.
    func tilt(_ sample: MotionTrail.Sample?, at time: Double, mode: HorizonMode, hold: HoldOrientation?) -> CGFloat {
        state.with { state -> CGFloat in
            guard mode != .off, let sample else {
                state = State()
                return 0
            }
            if state.time == nil || state.mode != mode {
                state = State(mode: mode, time: time, roll: sample.roll, angle: sample.roll)
            }
            let elapsed = min(max(time - (state.time ?? time), 0), 0.2)
            state.time = time
            state.roll += (sample.roll - state.roll) * (1 - exp(-elapsed / Self.settle))
            // Flat on its back the roll is noise; the cut keeps the turn it had.
            guard sample.upright else { return CGFloat(state.tilt) }
            switch mode {
            case .off:
                state.tilt = 0
            case .level:
                let level = (hold ?? HoldOrientation.nearest(to: HoldOrientation.normalized(state.roll))).angle
                state.tilt = HoldOrientation.normalized(state.roll - level)
            case .smooth:
                let predicted = state.angle + state.speed * elapsed
                let surprise = state.roll - predicted
                state.angle = predicted + Self.alpha * surprise
                state.speed += Self.beta * surprise / max(elapsed, 1.0 / 60)
                state.tilt = state.roll - state.angle
            }
            return CGFloat(state.tilt)
        }
    }
}
