import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The color step. Every LUT goes through `CIColorCubeWithColorSpace`; built-in looks call their Core Image filter.
enum ColorGrader {
    /// The LUTs were made on sRGB images. Core Image converts the P3 working space in and out.
    private static let lutSpace = CGColorSpace(name: CGColorSpace.sRGB)

    static func apply(_ image: CIImage, grade: LookGrade) -> CIImage {
        switch grade {
        case .none:
            return image
        case .lut(let lut):
            return self.lut(image, name: lut.imageName)
        case .builtIn(let builtIn):
            guard let filter = CIFilter(name: builtIn.filterName) else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            return (filter.outputImage ?? image).cropped(to: image.extent)
        case .effect(let effect):
            return EffectChain.apply(image, grade: effect)
        }
    }

    /// A nil or missing name returns the image unchanged.
    static func lut(_ image: CIImage, name: String?) -> CIImage {
        guard let name, let data = LUTStore.shared.latticeData(named: name), let lutSpace else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(LUTStore.dimension)
        filter.cubeData = data
        filter.colorSpace = lutSpace
        filter.extrapolate = false
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }
}
