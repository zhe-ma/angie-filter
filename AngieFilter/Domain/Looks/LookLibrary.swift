import Foundation

enum LookLibrary {
    static let looks: [Look] = load()

    static let families: [LookFamily] = makeFamilies()

    static func look(id: Look.ID) -> Look {
        looks.first { $0.id == id } ?? original
    }

    static func family(containing lookID: Look.ID) -> LookFamily {
        families.first { family in family.looks.contains { $0.id == lookID } } ?? families[0]
    }

    static func family(id: String) -> LookFamily? {
        families.first { $0.id == id }
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

    private static let familySpecs: [(id: String, name: String, ids: [String])] = [
        ("original", "原图", [Look.originalID]),
        ("leica", "徕卡", ["natural", "classic", "bright", "mono"]),
        ("fuji", "富士", ["standard", "vivid", "soft", "chrome", "neg", "nostalgia", "real", "cinema", "bleach", "portrait", "portrait-hi", "acros", "pro400h", "superia"]),
        ("kodak", "柯达", ["portra160", "portra400", "portra800", "gold", "ektar", "ultramax", "colorplus", "kodachrome", "ektachrome", "trix", "tmax"]),
        ("cinema", "电影", ["cs800t", "cs50d", "cs400d", "v250d", "v500t"]),
        ("ricoh", "理光", ["positive", "negative", "hibw"]),
        ("hasselblad", "哈苏", ["hncs"]),
        ("ilford", "依尔福", ["hp5", "delta", "fp4", "xp2"]),
        ("polaroid", "宝丽来", ["sx70", "p600"]),
        ("digital", "数码", ["canon", "nikon", "sony"])
    ]

    private static func makeFamilies() -> [LookFamily] {
        let byID = Dictionary(uniqueKeysWithValues: looks.map { ($0.id, $0) })
        var used = Set<String>()
        var result: [LookFamily] = []
        for spec in familySpecs {
            let members = spec.ids.compactMap { id -> Look? in
                guard let look = byID[id] else { return nil }
                used.insert(id)
                return look
            }
            if !members.isEmpty {
                result.append(LookFamily(id: spec.id, name: spec.name, looks: members))
            }
        }
        let rest = looks.filter { !used.contains($0.id) }
        if !rest.isEmpty {
            result.append(LookFamily(id: "other", name: "其他", looks: rest))
        }
        if result.isEmpty {
            return [LookFamily(id: "original", name: "原图", looks: [original])]
        }
        return result
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
