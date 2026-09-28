import Foundation

enum GrainPlateKind: String, Equatable, Sendable, Decodable {
    case none
    case fine
    case coarse
}

struct Look: Identifiable, Equatable, Sendable {
    typealias ID = String

    let id: ID
    let name: String
    let about: String
    let grade: LookGrade

    static let originalID = "original"

    var isOriginal: Bool { id == Self.originalID }

    var clarity: Float { grade.colorCube?.clarity ?? 0 }
    var grain: Float { grade.colorCube?.grain ?? 0 }
    var grainPlate: GrainPlateKind { grade.colorCube?.grainPlate ?? .none }
    var vignette: Float { grade.colorCube?.vignette ?? 0 }

    /// Recipe looks expose clarity, grain, and vignette. LUT looks expose intensity only.
    var adjustsSpatially: Bool { grade.colorCube != nil }
}
