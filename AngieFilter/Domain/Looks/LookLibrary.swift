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
        grade: .none
    )

    /// Recipe looks ship in Looks.json. LUT looks ship in LUTLooks.json and are appended.
    private static func load() -> [Look] {
        let recipes = records(named: "Looks")
        guard !recipes.isEmpty else { return [original] }
        var seen = Set(recipes.map(\.id))
        var looks = recipes
        for look in records(named: "LUTLooks") where seen.insert(look.id).inserted {
            looks.append(look)
        }
        return looks
    }

    private static func records(named name: String) -> [Look] {
        let url = Bundle.main.url(forResource: name, withExtension: "json")
            ?? Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? bundledFile(named: "\(name).json")
        guard let url,
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([LookRecord].self, from: data) else {
            return []
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
        ("digital", "数码", ["canon", "nikon", "sony"]),
        ("lut-portrait", "人像", ["lut-ziran", "lut-qingtou", "lut-wenrou", "lut-baixi", "lut-fennen", "lut-candyb", "lut-dannai", "lut-musi", "lut-zhuguang", "lut-huoli", "lut-qingchun"]),
        ("lut-scenery", "风景", ["lut-xuanlan", "lut-chengjing", "lut-dushi", "lut-jiaoye"]),
        ("lut-food", "美食", ["lut-meiwei", "lut-xinxian", "lut-youge", "lut-lengcui"]),
        ("lut-fresh", "新锐", ["lut-yishigan", "lut-qingjiaopian", "lut-fugu", "lut-luoma", "lut-dianying", "lut-huidiao"])
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
    let clarity: Float?
    let grain: Float?
    let grainPlate: GrainPlateKind?
    let vignette: Float?
    let fade: Float?
    let shoulder: Float?
    let halation: Float?
    let skin: Float?
    let grade: String?
    let lutImage: String?
    let strength: Float?

    var look: Look {
        let finish = LookFinish(
            fade: fade ?? 0,
            shoulder: shoulder ?? 0,
            halation: halation ?? 0,
            skin: skin ?? 0
        )
        if id == Look.originalID {
            return Look(id: id, name: name, about: about, grade: .none, finish: finish)
        }
        if grade == "lutImage" {
            return Look(
                id: id,
                name: name,
                about: about,
                grade: .lutImage(LUTImageGrade(
                    imageName: lutImage ?? id,
                    strength: strength ?? 1
                )),
                finish: finish
            )
        }
        return Look(
            id: id,
            name: name,
            about: about,
            grade: .colorCube(ColorCubeGrade(
                cubeName: id,
                clarity: clarity ?? 0,
                grain: grain ?? 0,
                grainPlate: grainPlate ?? .none,
                vignette: vignette ?? 0
            )),
            finish: finish
        )
    }
}
