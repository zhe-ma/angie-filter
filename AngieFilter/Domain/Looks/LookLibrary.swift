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

    private static func load() -> [Look] {
        guard let url = Bundle.main.url(forResource: "Looks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([LookRecord].self, from: data) else {
            return [original]
        }
        let looks = records.compactMap(\.look)
        return looks.isEmpty ? [original] : looks
    }

    private static let familySpecs: [(id: String, name: String, ids: [String])] = [
        ("original", "原图", [Look.originalID]),
        ("kodak", "柯达", ["portra160", "portra400", "portra400vc", "portra800", "ektar100", "elite200", "elite400", "kodachrome64", "ektachrome100vs", "elitechrome200", "trix400", "tmax100", "bw400cn"]),
        ("fuji", "富士", ["pro400h", "pro160c", "pro800z", "superia200", "superia400", "superia800", "reala100", "velvia50", "provia100f", "astia100f", "acros100", "neopan1600"]),
        ("instant", "拍立得", ["fp100c", "polaroid669", "polaroid669cold", "polaroid690", "px70", "px680", "px100warm", "timezero", "polachrome", "polaroid665"]),
        ("mono", "黑白", ["hp5", "delta100", "delta3200", "fp4", "panf50", "xp2", "apx100", "retro100", "ortho25", "infrared"]),
        ("agfa", "爱克发", ["vista200", "precisa100", "ultra100", "xproslide", "redscale", "elitexpro"]),
        ("cinema", "电影感", ["tealorange", "bleachbypass", "crispwarm", "crispwinter", "softwarming", "latesunset", "fallcolors", "moonlight", "foggynight", "candlelight", "tealmagentagold"]),
        ("system", "系统", ["sys-chrome", "sys-fade", "sys-instant", "sys-process", "sys-transfer", "sys-mono", "sys-tonal", "sys-noir"])
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
        return result
    }
}

private struct LookRecord: Decodable {
    let id: String
    let name: String
    let about: String
    let grade: String?
    let lut: String?
    let filter: String?
    let strength: Float?
    let fade: Float?
    let halation: Float?
    let grain: Float?
    let grainPlate: GrainPlateKind?
    let vignette: Float?

    /// Nil for an unknown grade, so a bad entry is skipped instead of showing as the original.
    var look: Look? {
        guard id != Look.originalID else {
            return Look(id: id, name: name, about: about, grade: .none)
        }
        let resolved: LookGrade
        switch grade {
        case "lut":
            resolved = .lut(LUTGrade(imageName: lut ?? id, strength: min(max(strength ?? 1, 0), 1)))
        case "builtIn":
            guard let filter else { return nil }
            resolved = .builtIn(BuiltInGrade(filterName: filter))
        default:
            return nil
        }
        let plate = grainPlate ?? .fine
        return Look(
            id: id,
            name: name,
            about: about,
            grade: resolved,
            finish: LookFinish(
                fade: fade ?? 0,
                halation: halation ?? 0,
                grain: grain ?? 0,
                grainPlate: plate,
                vignette: vignette ?? 0
            )
        )
    }
}
