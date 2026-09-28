import Foundation

/// Which renderer a look uses. A new scheme is a new case plus a grader in CameraPipeline.
enum LookGrade: Equatable, Sendable {
    case none
    case colorCube(ColorCubeGrade)
    case lutImage(LUTImageGrade)

    var colorCube: ColorCubeGrade? {
        if case .colorCube(let grade) = self { return grade }
        return nil
    }
}

/// Baked 65³ recipe. Clarity, grain, and vignette stay outside the cube.
struct ColorCubeGrade: Equatable, Sendable {
    var cubeName: String
    var clarity: Float
    var grain: Float
    var grainPlate: GrainPlateKind
    var vignette: Float
}

/// 512×512 PNG, 8×8 tiles of 64×64. `strength` is the catalog mix, from 0 to 1.
struct LUTImageGrade: Equatable, Sendable {
    var imageName: String
    var strength: Float
}
