import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Expands 512×512 LUT PNGs into the float RGBA buffer `CIColorCubeWithColorSpace` takes.
/// One expanded cube is about 4MB. Sixteen covers the largest category plus the live preview.
final class LUTStore: @unchecked Sendable {
    static let shared = LUTStore()
    static let dimension = 64
    private static let side = 512

    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private var recent: [String] = []
    private let capacity = 16

    func latticeData(named name: String) -> Data? {
        if let cached = stored(name) { return cached }
        let start = PerfLog.now()
        guard let cgImage = Self.loadImage(named: name), let data = Self.lattice(from: cgImage) else {
            PerfLog.line("lut \(name) failed to load")
            return nil
        }
        PerfLog.line(String(format: "lut %@ loaded in %.1f ms", name, PerfLog.ms(since: start)))
        return remember(data, name: name)
    }

    private func stored(_ name: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = cache[name] else { return nil }
        recent.removeAll { $0 == name }
        recent.append(name)
        return data
    }

    private func remember(_ data: Data, name: String) -> Data {
        lock.lock()
        defer { lock.unlock() }
        cache[name] = data
        recent.removeAll { $0 == name }
        recent.append(name)
        while recent.count > capacity {
            cache.removeValue(forKey: recent.removeFirst())
        }
        return data
    }

    private static func loadImage(named name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width == side, cgImage.height == side else {
            return nil
        }
        return cgImage
    }

    /// Blue 0 is the top-left tile; red runs across a tile and green down it.
    /// Each tile row is 64 consecutive lattice points, so rows convert in one call.
    private static func lattice(from cgImage: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        let dimension = Self.dimension
        let rowValues = dimension * 4
        var floats = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        pixels.withUnsafeBufferPointer { source in
            floats.withUnsafeMutableBufferPointer { destination in
                guard let from = source.baseAddress, let to = destination.baseAddress else { return }
                for blue in 0..<dimension {
                    let originX = (blue % 8) * dimension
                    let originY = (blue / 8) * dimension
                    for green in 0..<dimension {
                        let input = from + ((originY + green) * side + originX) * 4
                        let output = to + (green * dimension + blue * dimension * dimension) * 4
                        vDSP_vfltu8(input, 1, output, 1, vDSP_Length(rowValues))
                    }
                }
                var scale: Float = 1 / 255
                vDSP_vsmul(to, 1, &scale, to, 1, vDSP_Length(destination.count))
            }
        }
        for alpha in stride(from: 3, to: floats.count, by: 4) {
            floats[alpha] = 1
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
