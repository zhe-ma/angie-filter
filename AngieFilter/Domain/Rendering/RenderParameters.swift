import CoreGraphics
import ImageIO

struct LookAdjustment: Equatable, Sendable {
    var intensity: Float = 1
    var clarity: Float = 0
    var grain: Float = 0
    var vignette: Float = 0

    static func baseline(for look: Look) -> LookAdjustment {
        LookAdjustment(
            intensity: 1,
            clarity: look.clarity,
            grain: look.grain,
            vignette: look.vignette
        )
    }
}

struct RenderParameters: Equatable, Sendable {
    var aspectRatio: AspectRatio = .fourThree
    var lookID: Look.ID = Look.originalID
    var adjustment = LookAdjustment()
    var orientation: CGImagePropertyOrientation = .right
    var mirrorHorizontally = false
    var quality: RenderQuality = .preview
}

enum RenderQuality: Equatable, Sendable {
    case preview
    case still
}
