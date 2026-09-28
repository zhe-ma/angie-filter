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
    var finish = LookFinish()

    static let originalID = "original"

    var isOriginal: Bool { id == Self.originalID }

    var clarity: Float { grade.colorCube?.clarity ?? 0 }
    var grain: Float { grade.colorCube?.grain ?? 0 }
    var grainPlate: GrainPlateKind { grade.colorCube?.grainPlate ?? .none }
    var vignette: Float { grade.colorCube?.vignette ?? 0 }

    /// Recipe looks expose clarity, grain, and vignette.
    var adjustsSpatially: Bool { grade.colorCube != nil }

    /// Halation stays hidden unless this look ships with it.
    var showsHalation: Bool { finish.halation > 0.001 }
}
