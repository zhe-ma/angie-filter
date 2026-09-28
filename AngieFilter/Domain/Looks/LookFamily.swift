import Foundation

struct LookFamily: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let looks: [Look]
}
