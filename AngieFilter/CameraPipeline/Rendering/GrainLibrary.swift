import CoreImage
import Foundation

enum GrainLibrary {
    static func image(for kind: GrainPlateKind) -> CIImage? {
        switch kind {
        case .none:
            return nil
        case .fine:
            return fine
        case .coarse:
            return coarse
        }
    }

    private static let fine = load("fine")
    private static let coarse = load("coarse")

    private static func load(_ name: String) -> CIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = CIImage(contentsOf: url) else { return nil }
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}
