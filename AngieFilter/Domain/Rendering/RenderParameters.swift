import CoreGraphics
import ImageIO

struct LookAdjustment: Equatable, Sendable {
    var intensity: Float = 1
    var fade: Float = 0
    var halation: Float = 0
    var grain: Float = 0
    var vignette: Float = 0

    static func baseline(for look: Look) -> LookAdjustment {
        guard !look.isOriginal else { return LookAdjustment() }
        return LookAdjustment(
            intensity: look.strength,
            fade: look.finish.fade,
            halation: look.finish.halation,
            grain: look.finish.grain,
            vignette: look.finish.vignette
        )
    }
}

struct RenderParameters: Equatable, Sendable {
    var aspectRatio: AspectRatio = .fourThree
    var lookID: Look.ID = Look.originalID
    var adjustment = LookAdjustment()
    var frame = FrameSettings()
    /// Marketing name stamped by the session. Empty until the first update.
    var frameModelName = ""
    /// Calendar day printed on the caption, `yyyy.MM.dd`.
    var frameDate = ""
    /// City and district printed on the caption. Empty until a place resolves.
    var framePlace = ""
    var orientation: CGImagePropertyOrientation = .right
    var mirrorHorizontally = false
    var quality: RenderQuality = .preview
    /// Set while both cameras are composited. Nil on the single-camera path.
    var dual: DualSettings?
}

enum RenderQuality: Equatable, Sendable {
    case preview
    case still
    /// Filter strip. Color, fade, and vignette only; grain and halation are too small to see.
    case thumbnail
}
