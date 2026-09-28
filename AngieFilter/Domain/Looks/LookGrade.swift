import Foundation

/// Where a look's color comes from. Everything after the color step is shared, see `LookFinish`.
enum LookGrade: Equatable, Sendable {
    case none
    /// 512×512 sRGB PNG, 8×8 tiles of 64×64, sampled as a 64³ cube.
    case lut(LUTGrade)
    /// A Core Image filter that takes only an input image, such as `CIPhotoEffectChrome`.
    case builtIn(BuiltInGrade)
}

struct LUTGrade: Equatable, Sendable {
    var imageName: String
    /// Catalog mix toward the original, from 0 to 1.
    var strength: Float
}

struct BuiltInGrade: Equatable, Sendable {
    var filterName: String
}
