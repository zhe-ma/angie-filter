import Foundation

/// A fixed chain rebuilt from a technique in another camera app's reverse-engineering report.
/// The numbers each chain uses are listed in design/competitor-effects.md.
enum EffectRecipe: String, Sendable, CaseIterable {
    case dazzFisheyeWide = "dazz-fisheye-w"
    case dazzFisheyeFull = "dazz-fisheye-f"
    case dazzLightLeak = "dazz-leak"
    case kapiDarkCorner = "kapi-darkcorner"
    case kapiXT30 = "kapi-xt30"
    case kapiDV = "kapi-5s"
    case kapiCCD = "kapi-gccd"
    case kapiOldPhone = "kapi-4s"
    case kapiLomo = "kapi-lomo"
    case kapiNN = "kapi-nn"
    case kapiFino = "kapi-fino35"
    case halideValencia = "halide-valencia"
    case halideNova = "halide-nova"
    case halideScarlet = "halide-scarlet"
    case halideNoir = "halide-noir"
    case lampaAutoLevels = "lampa-levels"
    case moodCrush = "mood-crush"
    case moodFaded = "mood-faded"
    case moodExpired = "mood-expired"
    case nomoAnalog = "nomo-analog"
    case nomoHardBW = "nomo-hardbw"
    case noFusionBloom = "nofusion-bloom"

    /// Moves pixels. The strength mix then blends against the moved image, not the original.
    var isLens: Bool {
        self == .dazzFisheyeWide || self == .dazzFisheyeFull
    }
}
