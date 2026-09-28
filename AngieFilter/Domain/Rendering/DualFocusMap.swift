import CoreGraphics

enum DualFocusMap {
    /// `cellPoint` is 0...1 inside the pane, origin at the top left.
    /// The cell is a center crop of the upright image, so the point is expanded
    /// back onto that image before the camera's portrait mapping.
    static func devicePoint(cellPoint: CGPoint, cellAspect: CGFloat, imageAspect: CGFloat, facing: CameraFacing) -> CGPoint {
        let full = uncrop(cellPoint, imageAspect: imageAspect, cellAspect: cellAspect)
        let mapped = facing == .front
            ? CGPoint(x: full.y, y: full.x)
            : CGPoint(x: full.y, y: 1 - full.x)
        return CGPoint(x: min(max(mapped.x, 0), 1), y: min(max(mapped.y, 0), 1))
    }

    private static func uncrop(_ point: CGPoint, imageAspect: CGFloat, cellAspect: CGFloat) -> CGPoint {
        guard imageAspect > 0, cellAspect > 0 else { return point }
        if imageAspect > cellAspect + 0.001 {
            let visible = cellAspect / imageAspect
            let origin = (1 - visible) / 2
            return CGPoint(x: origin + point.x * visible, y: point.y)
        }
        if imageAspect < cellAspect - 0.001 {
            let visible = imageAspect / cellAspect
            let origin = (1 - visible) / 2
            return CGPoint(x: point.x, y: origin + point.y * visible)
        }
        return point
    }
}
