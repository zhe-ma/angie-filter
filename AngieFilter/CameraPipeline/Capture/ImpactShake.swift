import CoreGraphics
import Foundation

/// 冲击 for 运镜: a hit on the beat, fired from the 运镜 button mid-take. The cut punches in, shakes hard and settles
/// within `length`, and a white flash fades out faster. All of it rides on the cut, so it's in the preview and the
/// movie alike.
enum ImpactShake {
    static let length: Double = 0.4
    private static let flashLength: Double = 0.15
    private static let punch: Double = 0.07
    private static let shift: Double = 0.02
    private static let angle: Double = 1.2 * .pi / 180
    private static let flash: CGFloat = 0.6

    /// The cut's offset `elapsed` seconds after the hit; nil once it has settled.
    static func offset(after elapsed: Double) -> HandheldSway.Offset? {
        guard elapsed >= 0, elapsed < length else { return nil }
        let left = 1 - elapsed / length
        let decay = left * left
        return HandheldSway.Offset(
            shift: CGPoint(x: shift * decay * sin(2 * .pi * 18 * elapsed),
                           y: shift * 0.75 * decay * sin(2 * .pi * 23 * elapsed + 1)),
            angle: CGFloat(angle * decay * sin(2 * .pi * 15 * elapsed + 2)),
            zoom: CGFloat(1 + punch * decay)
        )
    }

    /// Share of white laid over the picture `elapsed` seconds after the hit.
    static func flash(after elapsed: Double) -> CGFloat {
        guard elapsed >= 0, elapsed < flashLength else { return 0 }
        return flash * CGFloat(1 - elapsed / flashLength)
    }
}
