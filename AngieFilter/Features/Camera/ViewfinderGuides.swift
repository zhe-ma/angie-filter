import CoreMotion
import SwiftUI

/// Rule-of-thirds lines over the photo.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Path { path in
                for step in 1...2 {
                    let x = size.width * CGFloat(step) / 3
                    let y = size.height * CGFloat(step) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.55), lineWidth: 1)
            .shadow(color: .black.opacity(0.3), radius: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// One Core Motion feed for the camera screen. Gravity drives both how the phone is held,
/// which changes rarely, and the level, which the level view alone observes at 30Hz.
@MainActor
final class MotionHub {
    static let shared = MotionHub()

    let level = LevelMonitor()
    var onHold: ((HoldOrientation) -> Void)?
    private(set) var hold = HoldOrientation.portrait

    private let motion = CMMotionManager()
    private var smoothed = CMAcceleration(x: 0, y: -1, z: 0)
    /// A new hold must be this close to its own angle, so the phone does not flip at 45°.
    private static let holdCapture = Double.pi / 6

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let gravity = data?.gravity else { return }
            MainActor.assumeIsolated {
                self?.update(gravity)
            }
        }
    }

    private func update(_ gravity: CMAcceleration) {
        let k = 0.35
        smoothed = CMAcceleration(
            x: smoothed.x + (gravity.x - smoothed.x) * k,
            y: smoothed.y + (gravity.y - smoothed.y) * k,
            z: smoothed.z + (gravity.z - smoothed.z) * k
        )
        let upright = abs(smoothed.z) < 0.8
        let roll = atan2(smoothed.x, -smoothed.y)
        if upright {
            let candidate = HoldOrientation.nearest(to: roll)
            if candidate != hold, HoldOrientation.distance(candidate.angle, roll) < Self.holdCapture {
                hold = candidate
                onHold?(candidate)
            }
        }
        level.update(roll: roll, hold: hold, usable: upright)
    }
}

/// Roll measured from the current hold, so the level works in portrait, landscape, and upside down.
@MainActor
final class LevelMonitor: ObservableObject {
    /// Radians the phone is off true horizontal for its hold; positive when it leans right.
    @Published private(set) var deviation: Double = 0
    @Published private(set) var hold = HoldOrientation.portrait
    /// False when the phone lies flat or leans too far for a horizon to mean anything.
    @Published private(set) var usable = false

    fileprivate func update(roll: Double, hold: HoldOrientation, usable: Bool) {
        let next = HoldOrientation.normalized(roll - hold.angle)
        let nextUsable = usable && abs(next) < .pi / 4
        if hold != self.hold { self.hold = hold }
        if nextUsable != self.usable { self.usable = nextUsable }
        if abs(next - deviation) > 0.0005 { deviation = next }
    }
}

/// Two fixed stubs mark true horizontal for the way the phone is held; the middle bar follows the real horizon.
/// Within one degree all three join into one yellow line, with a light tick.
struct LevelIndicator: View {
    @ObservedObject private var monitor = MotionHub.shared.level

    private static let tolerance = Double.pi / 180

    var body: some View {
        let level = abs(monitor.deviation) < Self.tolerance
        let color = level ? Color.yellow : Color.white
        HStack(spacing: 0) {
            Capsule().fill(color.opacity(level ? 1 : 0.55)).frame(width: 28, height: 1.5)
            Spacer().frame(width: level ? 0 : 10)
            Capsule()
                .fill(color)
                .frame(width: 96, height: 1.5)
                .rotationEffect(.radians(level ? 0 : -monitor.deviation))
            Spacer().frame(width: level ? 0 : 10)
            Capsule().fill(color.opacity(level ? 1 : 0.55)).frame(width: 28, height: 1.5)
        }
        .rotationEffect(.radians(-monitor.hold.angle))
        .shadow(color: .black.opacity(0.35), radius: 2)
        .opacity(monitor.usable ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: level)
        .animation(.easeOut(duration: 0.2), value: monitor.usable)
        .sensoryFeedback(.selection, trigger: level) { _, now in now }
        .allowsHitTesting(false)
    }
}
