import CoreGraphics

/// A window into a frame for 运镜: a rectangle of `size` around `center`, turned `angle` radians counterclockwise,
/// that `FrameImageMaker.cut` scales back up to the whole frame.
struct FrameCut: Equatable, Sendable {
    var center: CGPoint
    var size: CGSize
    var angle: CGFloat = 0

    /// Takes a point of the frame to where it lands in the cut picture filling `extent`.
    func fill(_ extent: CGRect) -> CGAffineTransform? {
        guard size.width > 1, size.height > 1 else { return nil }
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: -angle))
            .concatenating(CGAffineTransform(scaleX: extent.width / size.width, y: extent.height / size.height))
            .concatenating(CGAffineTransform(translationX: extent.midX, y: extent.midY))
    }

    /// Half the width and height of the box the turned window takes up in the frame.
    static func reach(of size: CGSize, turned angle: CGFloat) -> CGSize {
        let c = abs(cos(angle))
        let s = abs(sin(angle))
        return CGSize(width: (size.width * c + size.height * s) / 2, height: (size.width * s + size.height * c) / 2)
    }

    /// The most a window of `size` can turn and still lie inside `extent`, centered, up to 30°.
    static func mostAngle(for size: CGSize, in extent: CGSize) -> CGFloat {
        func fits(_ angle: CGFloat) -> Bool {
            let reach = reach(of: size, turned: angle)
            return reach.width <= extent.width / 2 && reach.height <= extent.height / 2
        }
        var low: CGFloat = 0
        var high: CGFloat = .pi / 6
        guard fits(low) else { return 0 }
        if fits(high) { return high }
        for _ in 0..<16 {
            let middle = (low + high) / 2
            if fits(middle) { low = middle } else { high = middle }
        }
        return low
    }
}
