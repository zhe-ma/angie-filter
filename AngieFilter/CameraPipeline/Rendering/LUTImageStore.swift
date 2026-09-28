import CoreImage
import Foundation
import ImageIO

/// Keeps the LUT images for the open category. Bytes stay as stored; no color conversion.
/// A 512×512 image is about 1MB, so sixteen covers the largest category plus the live preview.
final class LUTImageStore: @unchecked Sendable {
    static let shared = LUTImageStore()
    static let side: CGFloat = 512
    static let latticeDimension = 64

    private let lock = NSLock()
    private var images: [String: CIImage] = [:]
    private var lattices: [String: Data] = [:]
    private var recentImages: [String] = []
    private var recentLattices: [String] = []
    private let capacity = 16

    func image(named name: String) -> CIImage? {
        if let cached = storedImage(name) { return cached }
        guard let loaded = Self.loadImage(named: name) else { return nil }
        return remember(loaded, name: name)
    }

    /// 64³ lattice sampled from the PNG. Used when the lookup kernel cannot be built.
    func latticeData(named name: String) -> Data? {
        if let cached = storedLattice(name) { return cached }
        guard let cgImage = Self.loadCGImage(named: name),
              let data = Self.latticeData(from: cgImage) else { return nil }
        return rememberLattice(data, name: name)
    }

    private func storedImage(_ name: String) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let image = images[name] else { return nil }
        recentImages.removeAll { $0 == name }
        recentImages.append(name)
        return image
    }

    private func remember(_ image: CIImage, name: String) -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        images[name] = image
        recentImages.removeAll { $0 == name }
        recentImages.append(name)
        while recentImages.count > capacity {
            images.removeValue(forKey: recentImages.removeFirst())
        }
        return image
    }

    private func storedLattice(_ name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = lattices[name] else { return nil }
        recentLattices.removeAll { $0 == name }
        recentLattices.append(name)
        return data
    }

    private func rememberLattice(_ data: Data, name: String) -> Data {
        lock.lock()
        defer { lock.unlock() }
        lattices[name] = data
        recentLattices.removeAll { $0 == name }
        recentLattices.append(name)
        while recentLattices.count > capacity {
            lattices.removeValue(forKey: recentLattices.removeFirst())
        }
        return data
    }

    private static func loadImage(named name: String) -> CIImage? {
        guard let cgImage = loadCGImage(named: name) else { return nil }
        let raw = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
        return raw.transformed(by: CGAffineTransform(
            translationX: -raw.extent.origin.x,
            y: -raw.extent.origin.y
        )).cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private static func loadCGImage(named name: String) -> CGImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "LUTs")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Resources/LUTs")
            ?? bundledFile(named: "\(name).png")
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width == Int(side), cgImage.height == Int(side) else {
            return nil
        }
        return cgImage
    }

    /// Point-samples the 8×8 grid into a 64³ cube. Blue 0 is the top-left tile.
    private static func latticeData(from cgImage: CGImage) -> Data? {
        let side = Int(Self.side)
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        let dimension = latticeDimension
        let scale = Float(dimension - 1)
        var floats = [Float](repeating: 1, count: dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            let row = blue / 8
            let column = blue % 8
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let redValue = Float(red) / scale
                    let greenValue = Float(green) / scale
                    let xNorm = Float(column) / 8 + 0.5 / 512 + (1.0 / 8 - 1.0 / 512) * redValue
                    let yNorm = Float(row) / 8 + 0.5 / 512 + (1.0 / 8 - 1.0 / 512) * greenValue
                    let x = min(side - 1, max(0, Int(xNorm * 512)))
                    let y = min(side - 1, max(0, Int(yNorm * 512)))
                    let source = (y * side + x) * 4
                    let destination = (red + green * dimension + blue * dimension * dimension) * 4
                    floats[destination] = Float(pixels[source]) / 255
                    floats[destination + 1] = Float(pixels[source + 1]) / 255
                    floats[destination + 2] = Float(pixels[source + 2]) / 255
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
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
