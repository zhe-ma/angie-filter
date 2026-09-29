import CoreGraphics

/// A face found in a frame, for 美颜. `bounds` is normalized to that frame with the origin at the bottom left.
struct FaceRegion: Equatable, Sendable {
    var bounds: CGRect
    /// Radians, counterclockwise on the upright picture.
    var roll: CGFloat = 0

    /// The skin to retouch as an ellipse in pixels: the detector's box runs from the brows to the chin,
    /// so the ellipse sits a little higher to take in the forehead.
    func ellipse(in extent: CGRect) -> (center: CGPoint, radii: CGSize) {
        let width = bounds.width * extent.width
        let height = bounds.height * extent.height
        let lift = height * 0.12
        let center = CGPoint(
            x: extent.minX + bounds.midX * extent.width - sin(roll) * lift,
            y: extent.minY + bounds.midY * extent.height + cos(roll) * lift
        )
        return (center, CGSize(width: width * 0.6, height: height * 0.78))
    }
}
