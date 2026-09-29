import CoreImage
import Foundation

/// Kernels from `EffectKernels.metal`. A missing kernel leaves its stage out instead of failing the frame.
enum EffectKernels {
    static let fisheye = warp("dazzFisheye")
    static let aberration = general("dazzAberration")
    static let softLight = color("kapiSoftLight")
    static let multiply = color("kapiMultiply")
    static let brightPass = color("brightPass")
    static let halationTrim = color("halationTrim")
    static let addColor = color("addColor")
    static let subtract = color("subtractImage")
    static let mtfCombine = color("mtfCombine")
    static let screenExpand = color("screenExpand")
    static let screenCompress = color("screenCompress")
    static let screenLinear = color("screenLinear")
    static let screenAppleLog = color("screenAppleLog")
    static let screenMist = color("screenMist")
    static let screenBright = color("screenBright")
    static let screenHalation = color("screenHalation")
    static let skinMask = color("skinMask")
    static let skinSmooth = color("skinSmooth")
    static let skinRelight = color("skinRelight")
    static let skinChromaPack = color("skinChromaPack")
    static let skinFinish = color("skinFinish")
    static let zoomBlur = general("zoomBlur")
    static let peopleOut = color("peopleOut")
    static let peopleIn = color("peopleIn")
    static let peopleOver = color("peopleOver")

    private static let library: Data? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            PerfLog.line("effect kernels: default.metallib missing")
            return nil
        }
        return try? Data(contentsOf: url)
    }()

    private static func color(_ name: String) -> CIColorKernel? {
        load(name) { try CIColorKernel(functionName: name, fromMetalLibraryData: $0) }
    }

    private static func warp(_ name: String) -> CIWarpKernel? {
        load(name) { try CIWarpKernel(functionName: name, fromMetalLibraryData: $0) }
    }

    private static func general(_ name: String) -> CIKernel? {
        load(name) { try CIKernel(functionName: name, fromMetalLibraryData: $0) }
    }

    private static func load<Kernel>(_ name: String, _ make: (Data) throws -> Kernel) -> Kernel? {
        guard let library else { return nil }
        do {
            return try make(library)
        } catch {
            PerfLog.line("effect kernel \(name) failed: \(error)")
            return nil
        }
    }
}
