import Foundation

/// Shared finish after the color step. Shoulder and skin stay at the catalog value.
struct LookFinish: Equatable, Sendable {
    var fade: Float = 0
    var shoulder: Float = 0
    var halation: Float = 0
    var skin: Float = 0
}
