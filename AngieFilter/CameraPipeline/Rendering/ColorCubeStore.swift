import Foundation

/// Loads a baked 65³ cube and expands it into the float buffer
/// `CIColorCubeWithColorSpace` samples. One expanded cube is about 4.4MB.
/// The cache holds a whole category so thumbnail refresh does not evict the live preview.
final class ColorCubeStore: @unchecked Sendable {
    static let shared = ColorCubeStore()
    static let dimension = 65

    private let lock = NSLock()
    private var cache: [String: Data] = [:]
    private var recent: [String] = []
    private let capacity = 16

    func data(named name: String) -> Data? {
        if let cached = stored(name) { return cached }
        guard let expanded = Self.expand(named: name) else { return nil }
        return remember(expanded, name: name)
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

    private static func expand(named name: String) -> Data? {
        let url = Bundle.main.url(forResource: name, withExtension: "acube")
            ?? Bundle.main.url(forResource: name, withExtension: "acube", subdirectory: "ColorCubes")
            ?? Bundle.main.url(forResource: name, withExtension: "acube", subdirectory: "Resources/ColorCubes")
            ?? bundledFile(named: "\(name).acube")
        guard let url, let file = try? Data(contentsOf: url) else { return nil }
        return expand(file)
    }

    /// File layout: "AC65", UInt16 dimension, UInt16 version, then RGB with red fastest.
    /// Version 2 stores Float16 so highlight values above 1 and negative channels survive.
    static func expand(_ file: Data) -> Data? {
        guard file.count >= 8, file.prefix(4) == Data("AC65".utf8) else { return nil }
        let dimension = Int(file[4]) | (Int(file[5]) << 8)
        let version = Int(file[6]) | (Int(file[7]) << 8)
        guard dimension == Self.dimension, version == 2 else { return nil }
        let count = dimension * dimension * dimension
        guard file.count == 8 + count * 6 else { return nil }

        var floats = [Float](repeating: 1, count: count * 4)
        file.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in 0..<count {
                let source = 8 + index * 6
                let destination = index * 4
                for channel in 0..<3 {
                    let offset = source + channel * 2
                    let bits = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                    floats[destination + channel] = Float(Float16(bitPattern: bits))
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
