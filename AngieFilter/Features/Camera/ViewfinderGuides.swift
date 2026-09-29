import CoreMotion
import SwiftUI

/// Rule-of-thirds hairlines over the photo.
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
            .stroke(Color.white.opacity(0.32), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Device roll in portrait, from gravity. Observed only by `LevelIndicator`, so 30 updates a second
/// never reach the rest of the camera screen.
@MainActor
final class LevelMonitor: ObservableObject {
    /// Radians; positive when the top of the phone leans right.
    @Published private(set) var roll: Double = 0
    /// False when the phone lies flat or is held sideways, where a portrait horizon means nothing.
    @Published private(set) var usable = false

    private let motion = CMMotionManager()

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

    func stop() {
        motion.stopDeviceMotionUpdates()
    }

    private func update(_ gravity: CMAcceleration) {
        let raw = atan2(gravity.x, -gravity.y)
        let next = roll + (raw - roll) * 0.35
        let nextUsable = abs(gravity.z) < 0.85 && abs(raw) < .pi / 4
        if nextUsable != usable { usable = nextUsable }
        if abs(next - roll) > 0.0005 { roll = next }
    }
}

/// Two fixed stubs mark true horizontal; the middle bar follows the real horizon.
/// Within one degree all three join into one yellow line, with a light tick.
struct LevelIndicator: View {
    @StateObject private var monitor = LevelMonitor()

    private static let tolerance = Double.pi / 180

    var body: some View {
        let level = abs(monitor.roll) < Self.tolerance
        let color = level ? Color.yellow : Color.white
        HStack(spacing: 0) {
            Capsule().fill(color.opacity(level ? 1 : 0.55)).frame(width: 28, height: 1.5)
            Spacer().frame(width: level ? 0 : 10)
            Capsule()
                .fill(color)
                .frame(width: 96, height: 1.5)
                .rotationEffect(.radians(level ? 0 : -monitor.roll))
            Spacer().frame(width: level ? 0 : 10)
            Capsule().fill(color.opacity(level ? 1 : 0.55)).frame(width: 28, height: 1.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 2)
        .opacity(monitor.usable ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: level)
        .animation(.easeOut(duration: 0.2), value: monitor.usable)
        .sensoryFeedback(.selection, trigger: level) { _, now in now }
        .allowsHitTesting(false)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }
}
