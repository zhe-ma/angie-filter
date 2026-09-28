import Foundation

enum LookLibrary {
    static let looks: [Look] = load()

    static func look(id: Look.ID) -> Look {
        looks.first { $0.id == id } ?? original
    }

    static let original = Look(
        id: Look.originalID,
        name: "原图",
        about: "不套风格。",
        clarity: 0,
        grain: 0,
        grainPlate: .none,
        vignette: 0
    )

    /// Names and the spatial settings (clarity, grain, vignette) ship in Looks.json.
    /// Color for every other look is a baked cube from Tools/BakeColorCubes.swift.
    private static func load() -> [Look] {
        let url = Bundle.main.url(forResource: "Looks", withExtension: "json")
            ?? Bundle.main.url(forResource: "Looks", withExtension: "json", subdirectory: "Resources")
            ?? bundledFile(named: "Looks.json")
        guard let url,
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([LookRecord].self, from: data),
              !records.isEmpty else {
            return [original]
        }
        return records.map(\.look)
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

private struct LookRecord: Decodable {
    let id: String
    let name: String
    let about: String
    let clarity: Float
    let grain: Float
    let grainPlate: GrainPlateKind
    let vignette: Float

    var look: Look {
        Look(
            id: id,
            name: name,
            about: about,
            clarity: clarity,
            grain: grain,
            grainPlate: grainPlate,
            vignette: vignette
        )
    }
}
