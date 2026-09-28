import CoreGraphics
import ImageIO

struct RenderParameters: Equatable, Sendable {
    var aspectRatio: AspectRatio = .fourThree
    var lookID: Look.ID = Look.originalID
    var intensity: Float = 1
    var orientation: CGImagePropertyOrientation = .right
    var mirrorHorizontally = false
    var quality: RenderQuality = .preview
}

enum RenderQuality: Equatable, Sendable {
    case preview
    case still
}
