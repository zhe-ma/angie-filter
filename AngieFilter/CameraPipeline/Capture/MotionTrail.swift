import CoreMotion
import QuartzCore

/// The phone's roll and turn rates at a frame's time, for 运镜's leveling and whip blur. Device motion runs at
/// 100 Hz while 运镜 is on; its timestamps and the frames' presentation times are both on the host clock, so a frame
/// held back by stabilization still finds the motion from when it was shot.
final class MotionTrail: @unchecked Sendable {
    struct Sample {
        /// Radians, positive when the top leans right; unwrapped, so it runs on past ±π as the phone keeps turning.
        var roll: Double
        /// Gravity lies mostly in the screen's plane, so the roll means something; flat on its back it doesn't.
        var upright: Bool
        /// Radians a second about the phone's own axes: x across the screen, y up it, z out of it.
        var rate: SIMD3<Double>
        /// Radians about gravity from an arbitrary start, unwrapped: how far the phone has turned to circle round.
        var yaw: Double = 0
    }

    private static let interval: TimeInterval = 1.0 / 100
    private static let history: Double = 1.5

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "angie.motion"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let samples = Locked<[(time: Double, sample: Sample)]>([])

    var isOn: Bool {
        manager.isDeviceMotionActive
    }

    /// Call on one queue, like the session's.
    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = Self.interval
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let g = motion.gravity
            let rate = motion.rotationRate
            self.samples.with { samples in
                var roll = atan2(g.x, -g.y)
                var yaw: Double = 0
                if let last = samples.last {
                    roll = last.sample.roll + HoldOrientation.normalized(roll - last.sample.roll)
                    // The turn about gravity, summed; Euler yaw locks up with the phone held upright.
                    let length = max((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 0.001)
                    let aboutUp = -(rate.x * g.x + rate.y * g.y + rate.z * g.z) / length
                    yaw = last.sample.yaw + aboutUp * min(max(motion.timestamp - last.time, 0), 0.1)
                }
                let sample = Sample(roll: roll, upright: g.x * g.x + g.y * g.y > 0.25,
                                    rate: SIMD3(rate.x, rate.y, rate.z), yaw: yaw)
                samples.append((motion.timestamp, sample))
                if let kept = samples.firstIndex(where: { $0.time >= motion.timestamp - Self.history }), kept > 0 {
                    samples.removeFirst(kept)
                }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        samples.with { $0 = [] }
    }

    /// Between the samples around `time`, on the host clock; the nearest at either end.
    func sample(at time: Double) -> Sample? {
        samples.with { samples in
            guard let first = samples.first, let last = samples.last else { return nil }
            if time <= first.time { return first.sample }
            if time >= last.time { return last.sample }
            var high = samples.count - 1
            var low = 0
            while high - low > 1 {
                let middle = (low + high) / 2
                if samples[middle].time < time { low = middle } else { high = middle }
            }
            let earlier = samples[low]
            let later = samples[high]
            let share = (time - earlier.time) / max(later.time - earlier.time, 0.0001)
            return Sample(
                roll: earlier.sample.roll + share * (later.sample.roll - earlier.sample.roll),
                upright: earlier.sample.upright && later.sample.upright,
                rate: earlier.sample.rate + share * (later.sample.rate - earlier.sample.rate),
                yaw: earlier.sample.yaw + share * (later.sample.yaw - earlier.sample.yaw)
            )
        }
    }
}
