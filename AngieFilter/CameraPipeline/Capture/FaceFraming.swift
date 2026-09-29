import CoreGraphics
import QuartzCore

/// 跟拍 for 运镜: while it's on the picture is cut `scale` times in, which leaves a margin to slide the cut in.
/// During a take the cut follows the face so it stays where it was in the frame when the take started: the zoom
/// only moves toward the middle, so an off-center face drifts out as it zooms in, and a step's sway grows with the
/// focal length. After the take the cut drifts back to the middle.
/// The device zoom still does the scaling; the cut only slides, so its softness stays the same through a take.
final class FaceFraming: @unchecked Sendable {
    static let scale: CGFloat = 1.25
    /// Seconds for the cut to cover about two thirds of the way to where the face wants it.
    private static let settle: Double = 0.3
    /// Target moves smaller than this, in frame widths, are the detector's wobble.
    private static let deadBand: CGFloat = 0.004
    private static let middle = CGPoint(x: 0.5, y: 0.5)

    private struct State {
        var on = false
        var following = false
        var extent: CGSize = .zero
        /// The cut's center and where it's heading, normalized to the uncut frame.
        var center = FaceFraming.middle
        var target = FaceFraming.middle
        /// Where the face sat from the cut's center at the take's first sighting.
        var offset: CGPoint?
        var time: Double?
    }

    private let state = Locked(State())

    /// Off leaves the picture whole.
    func setOn(_ on: Bool) {
        state.with { state in
            if on {
                state.on = true
            } else {
                state = State()
            }
        }
    }

    /// On keeps the face where the next sighting finds it; call again when a new framing should be kept.
    func follow(_ on: Bool) {
        state.with { state in
            state.following = on
            state.offset = nil
            if !on {
                state.target = Self.middle
            }
        }
    }

    /// `face` is normalized to an uncut frame of `extent`.
    func sight(_ face: CGRect, extent: CGSize) {
        state.with { state in
            guard state.on, state.following, extent == state.extent else { return }
            let spot = CGPoint(x: face.midX, y: face.midY)
            guard let offset = state.offset else {
                state.offset = CGPoint(x: spot.x - state.center.x, y: spot.y - state.center.y)
                return
            }
            let wanted = Self.clamped(CGPoint(x: spot.x - offset.x, y: spot.y - offset.y))
            if hypot(wanted.x - state.target.x, wanted.y - state.target.y) >= Self.deadBand {
                state.target = wanted
            }
        }
    }

    /// On the video queue, once a frame: where to cut an uncut frame of `extent`, or nil to leave it whole.
    func cut(for extent: CGRect, at now: Double) -> CGRect? {
        state.with { state -> CGRect? in
            guard state.on, extent.width > 1, extent.height > 1 else { return nil }
            if state.extent != extent.size {
                // A new aspect frames the face differently; start from the middle.
                state.extent = extent.size
                state.center = Self.middle
                state.target = Self.middle
                state.offset = nil
                state.time = nil
            }
            let elapsed = state.time.map { max(now - $0, 0) } ?? 0
            state.time = now
            let share = CGFloat(1 - exp(-elapsed / Self.settle))
            state.center.x += (state.target.x - state.center.x) * share
            state.center.y += (state.target.y - state.center.y) * share
            let width = extent.width / Self.scale
            let height = extent.height / Self.scale
            return CGRect(
                x: extent.minX + state.center.x * extent.width - width / 2,
                y: extent.minY + state.center.y * extent.height - height / 2,
                width: width,
                height: height
            )
        }
    }

    /// Keeps the cut inside the frame.
    private static func clamped(_ point: CGPoint) -> CGPoint {
        let half = 0.5 / scale
        return CGPoint(x: min(max(point.x, half), 1 - half), y: min(max(point.y, half), 1 - half))
    }
}
