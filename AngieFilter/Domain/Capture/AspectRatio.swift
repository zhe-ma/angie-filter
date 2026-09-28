import CoreGraphics

enum AspectRatio: String, CaseIterable, Sendable {
    case fourThree = "4:3"
    case sixteenNine = "16:9"
    case square = "1:1"

    /// Width divided by height after the image is turned upright.
    var widthOverHeight: CGFloat {
        switch self {
        case .fourThree:
            return 3.0 / 4.0
        case .sixteenNine:
            return 16.0 / 9.0
        case .square:
            return 1
        }
    }

    func next() -> AspectRatio {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self) ?? 0
        return cases[(index + 1) % cases.count]
    }
}
