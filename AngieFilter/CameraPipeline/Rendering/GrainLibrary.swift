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
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Grain")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources/Grain")
            ?? bundledFile(named: "\(name).png")
        guard let url, let image = CIImage(contentsOf: url) else { return nil }
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    private static func bundledFile(named name: String) -> URL? {
        guard let root = Bundle.main.resourceURL else { return nil }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }
}
