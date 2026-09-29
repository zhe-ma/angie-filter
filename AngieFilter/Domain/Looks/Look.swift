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

    /// First mix toward the original when this look is picked.
    var strength: Float {
        switch grade {
        case .lut(let grade): return grade.strength
        case .effect(let grade): return grade.strength
        case .none, .builtIn: return 1
        }
    }

    /// Halation stays hidden unless this look ships with it.
    var showsHalation: Bool { finish.halation > 0.001 }
}
