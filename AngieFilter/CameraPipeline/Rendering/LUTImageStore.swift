import CoreImage
import Foundation
import ImageIO

/// Keeps the most recently used 512×512 LUT image. Bytes stay as stored; no color conversion.
final class LUTImageStore: @unchecked Sendable {
    static let shared = LUTImageStore()
    static let side: CGFloat = 512

    private let lock = NSLock()
    private var cachedName: String?
    private var cachedImage: CIImage?

    func image(named name: String) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        if cachedName == name, let cachedImage {
            return cachedImage
        }
        guard let loaded = Self.load(named: name) else { return nil }
        cachedName = name
        cachedImage = loaded
        return loaded
    }

    private static func load(named name: String) -> CIImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "LUTs")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources/LUTs")
            ?? bundledFile(named: "\(name).png")
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        guard cgImage.width == Int(side), cgImage.height == Int(side) else { return nil }
        let raw = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
        return raw.transformed(by: CGAffineTransform(
            translationX: -raw.extent.origin.x,
            y: -raw.extent.origin.y
        )).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
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
