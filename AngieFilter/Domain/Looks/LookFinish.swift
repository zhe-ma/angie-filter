import Foundation

/// Catalog defaults for the steps after color. Every look except the original can adjust them.
struct LookFinish: Equatable, Sendable {
    var fade: Float = 0
    var halation: Float = 0
    var grain: Float = 0
    var grainPlate: GrainPlateKind = .none
    var vignette: Float = 0
}
