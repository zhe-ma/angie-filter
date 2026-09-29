import CoreGraphics
import Foundation

/// 手持感 for 运镜: a slow drift of the cut, as if the camera were held by hand and breathing. Each part sums two
/// sines at unrelated frequencies between 0.15 and 0.5 Hz, so the drift never visibly repeats.
enum HandheldSway {
    struct Offset {
        /// In frame widths and heights.
        var shift: CGPoint = .zero
        /// Radians, counterclockwise.
        var angle: CGFloat = 0
        /// At least 1: the cut only ever goes in, so the drift never runs out of margin.
        var zoom: CGFloat = 1

        /// Both at once: shifts and turns add, zooms multiply.
        func adding(_ other: Offset?) -> Offset {
            guard let other else { return self }
            return Offset(shift: CGPoint(x: shift.x + other.shift.x, y: shift.y + other.shift.y),
                          angle: angle + other.angle, zoom: zoom * other.zoom)
        }
    }

    private static let shift: Double = 0.012
    private static let angle: Double = 0.5 * .pi / 180
    private static let zoom: Double = 0.012

    static func offset(at time: Double) -> Offset {
        func wave(_ first: Double, _ second: Double, _ phase: Double) -> Double {
            0.6 * sin(2 * .pi * first * time + phase) + 0.4 * sin(2 * .pi * second * time + phase * 1.7)
        }
        return Offset(
            shift: CGPoint(x: Self.shift * wave(0.23, 0.41, 0.0), y: Self.shift * wave(0.19, 0.37, 1.3)),
            angle: CGFloat(Self.angle * wave(0.17, 0.29, 2.1)),
            zoom: CGFloat(1 + Self.zoom * (0.5 + 0.5 * wave(0.15, 0.31, 0.7)))
        )
    }
}
