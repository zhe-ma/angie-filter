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
    let clarity: Float
    let grain: Float
    let grainPlate: GrainPlateKind
    let vignette: Float

    static let originalID = "original"

    var isOriginal: Bool { id == Self.originalID }

    /// Baked 65³ color cube in the bundle. Absent for 原图.
    var colorCubeName: String? { isOriginal ? nil : id }
}
