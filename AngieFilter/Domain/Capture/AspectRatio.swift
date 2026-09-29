import CoreGraphics

/// Labels read width:height of the upright photo.
enum AspectRatio: String, CaseIterable, Identifiable, Sendable {
    case threeFour = "3:4"
    case twoThree = "2:3"
    case nineSixteen = "9:16"
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case sixteenNine = "16:9"
    case twoOne = "2:1"
    /// Flat and scope, the two widescreen projection ratios.
    case flat = "1.85:1"
    case scope = "2.39:1"

    var id: String { rawValue }

    var widthOverHeight: CGFloat {
        switch self {
        case .threeFour: return 3.0 / 4.0
        case .twoThree: return 2.0 / 3.0
        case .nineSixteen: return 9.0 / 16.0
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeTwo: return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .twoOne: return 2
        case .flat: return 1.85
        case .scope: return 2.39
        }
    }
}
