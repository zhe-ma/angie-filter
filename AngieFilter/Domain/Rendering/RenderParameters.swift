import CoreGraphics
import ImageIO

struct LookAdjustment: Equatable, Sendable {
    var intensity: Float = 1
    var fade: Float = 0
    var halation: Float = 0
    var clarity: Float = 0
    var grain: Float = 0
    var vignette: Float = 0

    static func baseline(for look: Look) -> LookAdjustment {
        switch look.grade {
        case .none:
            return LookAdjustment()
        case .colorCube(let grade):
            return LookAdjustment(
                intensity: 1,
                fade: look.finish.fade,
                halation: look.finish.halation,
                clarity: grade.clarity,
                grain: grade.grain,
                vignette: grade.vignette
            )
        case .lutImage(let grade):
            return LookAdjustment(
                intensity: grade.strength,
                fade: look.finish.fade,
                halation: look.finish.halation
            )
        }
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
}
