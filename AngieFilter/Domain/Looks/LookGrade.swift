import Foundation

/// Where a look's color comes from. Everything after the color step is shared, see `LookFinish`.
enum LookGrade: Equatable, Sendable {
    case none
    /// 512×512 sRGB PNG, 8×8 tiles of 64×64, sampled as a 64³ cube.
    case lut(LUTGrade)
    /// A Core Image filter that takes only an input image, such as `CIPhotoEffectChrome`.
    case builtIn(BuiltInGrade)
    /// A chain of stages taken from another app's technique, with an optional LUT inside it.
    case effect(EffectGrade)
    /// The 银幕 print LUT, with mist and halation worked in scene light around it.
    case screen(LUTGrade)
}

struct LUTGrade: Equatable, Sendable {
    var imageName: String
    /// Catalog mix toward the original, from 0 to 1.
    var strength: Float
}

struct BuiltInGrade: Equatable, Sendable {
    var filterName: String
}

struct EffectGrade: Equatable, Sendable {
    var recipe: EffectRecipe
    /// Stands in for the app's own LUT at the point its chain applies one. Nil keeps the input color.
    var lutName: String?
    /// Catalog mix toward the original, from 0 to 1.
    var strength: Float
}
