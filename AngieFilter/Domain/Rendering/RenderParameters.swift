import CoreGraphics
import ImageIO

struct LookAdjustment: Equatable, Sendable {
    var intensity: Float = 1
    var fade: Float = 0
    var halation: Float = 0
    var grain: Float = 0
    var vignette: Float = 0
    var diffusion: Float = 0

    static func baseline(for look: Look) -> LookAdjustment {
        guard !look.isOriginal else { return LookAdjustment() }
        return LookAdjustment(
            intensity: look.strength,
            fade: look.finish.fade,
            halation: look.finish.halation,
            grain: look.finish.grain,
            vignette: look.finish.vignette,
            diffusion: look.finish.diffusion
        )
    }
}

struct RenderParameters: Equatable, Sendable {
    var aspectRatio: AspectRatio = .threeFour
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
    /// Stills are turned to this after grading and before the frame. The preview ignores it.
    var hold: HoldOrientation = .portrait
    var quality: RenderQuality = .preview
    /// 美颜 strength, 0 to 1; 0 is off. Faces get skin smoothing, even color, and a soft highlight, under every look.
    var beauty: Float = 0
    /// Set while both cameras are composited. Nil on the single-camera path.
    var dual: DualSettings?
    /// 模糊, over whatever look: kept on the phone, and the same for both cameras in dual.
    var blur = BlurSettings()

    /// The blur needs to know where people are.
    var wantsPeople: Bool {
        quality != .thumbnail && blur.cutsOutPeople
    }
}

/// 模糊: a Gaussian blur laid over any look, before its color, the way a lens blurs before the film. Whole blurs the
/// picture evenly; 抠人 blurs the background and the people each by their own amount, so people can stay sharp over
/// a blurred background, or go soft themselves.
struct BlurSettings: Equatable, Sendable {
    enum Mode: String, Sendable {
        case whole
        case people
    }

    var on = false
    var mode = Mode.people
    /// Each 0 to 1, a share of the widest blur.
    var whole: Float = 0.5
    var background: Float = 0.6
    var people: Float = 0

    /// Blurs anything at all.
    var shows: Bool {
        guard on else { return false }
        switch mode {
        case .whole: return whole > 0.005
        case .people: return background > 0.005 || people > 0.005
        }
    }

    var cutsOutPeople: Bool { shows && mode == .people }

    /// One slider each.
    enum Part: String, CaseIterable, Identifiable, Sendable {
        case whole, background, people

        var id: Self { self }

        var title: String {
            switch self {
            case .whole: "模糊"
            case .background: "背景"
            case .people: "人物"
            }
        }
    }

    subscript(part: Part) -> Float {
        get {
            switch part {
            case .whole: whole
            case .background: background
            case .people: people
            }
        }
        set {
            let value = min(max(newValue, 0), 1)
            switch part {
            case .whole: whole = value
            case .background: background = value
            case .people: people = value
            }
        }
    }
}

enum RenderQuality: Equatable, Sendable {
    case preview
    case still
    /// Filter strip. Color, fade, and vignette only; grain and halation are too small to see.
    case thumbnail
}
