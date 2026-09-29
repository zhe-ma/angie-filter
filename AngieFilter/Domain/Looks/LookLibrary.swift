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

    /// `Looks.json` is rewritten by Tools/ImportFilmLUTs.swift. `LabLooks.json` and `ScreenLooks.json`
    /// are edited by hand; the 银幕 LUTs come from Tools/BakeScreenLUTs.py.
    private static func load() -> [Look] {
        let looks = records(named: "Looks").compactMap(\.look)
        guard !looks.isEmpty else { return [original] }
        return looks + records(named: "LabLooks").compactMap(\.look) + records(named: "ScreenLooks").compactMap(\.look)
    }

    private static func records(named name: String) -> [LookRecord] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([LookRecord].self, from: data) else {
            return []
        }
        return records
    }

    private static let familySpecs: [(id: String, name: String, ids: [String])] = [
        ("original", "原图", [Look.originalID]),
        ("screen", "银幕", ["screen-250d", "screen-50d", "screen-200t", "screen-golden", "screen-500t", "screen-500t-blue", "screen-premier"]),
        ("lab", "实验室", ["lab-fisheye-w", "lab-fisheye-f", "lab-leak", "lab-darkcorner", "lab-xt30", "lab-5s", "lab-gccd", "lab-4s", "lab-lomo", "lab-nn", "lab-fino35", "lab-valencia", "lab-nova", "lab-scarlet", "lab-noir", "lab-levels", "lab-crush", "lab-faded", "lab-expired", "lab-analog", "lab-hardbw", "lab-bloom"]),
        ("kodak", "柯达", ["portra160", "portra400", "portra400vc", "portra800", "ektar100", "elite200", "elite400", "kodachrome64", "ektachrome100vs", "elitechrome200", "trix400", "tmax100", "bw400cn"]),
        ("fuji", "富士", ["pro400h", "pro160c", "pro800z", "superia200", "superia400", "superia800", "reala100", "velvia50", "provia100f", "astia100f", "acros100", "neopan1600"]),
        ("fx-eterna55", "GFX 电影机", ["fx-eterna55-provia", "fx-eterna55-velvia", "fx-eterna55-astia", "fx-eterna55-classicchrome", "fx-eterna55-realaace", "fx-eterna55-proneg", "fx-eterna55-classicneg", "fx-eterna55-eterna", "fx-eterna55-eternabb", "fx-eterna55-acros"]),
        ("fx-gfx100ii", "GFX 无反", ["fx-gfx100ii-eterna", "fx-gfx100ii-eternabb"]),
        ("fx-gfx100rf", "GFX 固定镜头", ["fx-gfx100rf-eterna", "fx-gfx100rf-eternabb"]),
        ("fx-xt30iii", "X 无反", ["fx-xt30iii-eterna", "fx-xt30iii-eternabb"]),
        ("fx-x100vi", "X 固定镜头", ["fx-x100vi-eterna", "fx-x100vi-eternabb"]),
        ("stormcam", "StormCam", ["storm-losangeles", "storm-lapland", "storm-bali", "storm-milan", "storm-oslo", "storm-seville", "storm-reykjavik", "storm-queensland", "storm-prague", "storm-lasvegas", "storm-cannes", "storm-restore", "storm-natural", "storm-seoul", "storm-island", "storm-kamakura", "storm-manhattan", "storm-tuscany", "storm-shangrila", "storm-monochrome", "storm-modern", "storm-rome", "storm-gobi", "storm-london", "storm-istanbul", "storm-sydney", "storm-kiruna"]),
        ("halide", "Halide", ["halide-valencia", "halide-rembrandt", "halide-nova", "halide-zephyr", "halide-chromanoir", "halide-scarlet"]),
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
    let effect: String?
    let strength: Float?
    let fade: Float?
    let halation: Float?
    let grain: Float?
    let grainPlate: GrainPlateKind?
    let vignette: Float?
    let diffusion: Float?

    /// Nil for an unknown grade, so a bad entry is skipped instead of showing as the original.
    var look: Look? {
        guard id != Look.originalID else {
            return Look(id: id, name: name, about: about, grade: .none)
        }
        let resolved: LookGrade
        switch grade {
        case "lut":
            resolved = .lut(LUTGrade(imageName: lut ?? id, strength: min(max(strength ?? 1, 0), 1)))
        case "screen":
            resolved = .screen(LUTGrade(imageName: lut ?? id, strength: min(max(strength ?? 1, 0), 1)))
        case "builtIn":
            guard let filter else { return nil }
            resolved = .builtIn(BuiltInGrade(filterName: filter))
        case "effect":
            guard let recipe = effect.flatMap(EffectRecipe.init(rawValue:)) else { return nil }
            resolved = .effect(EffectGrade(recipe: recipe, lutName: lut, strength: min(max(strength ?? 1, 0), 1)))
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
                vignette: vignette ?? 0,
                diffusion: diffusion ?? 0
            )
        )
    }
}
