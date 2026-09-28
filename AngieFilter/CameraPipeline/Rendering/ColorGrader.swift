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
            return applyLUT(image, name: lut.imageName)
        case .builtIn(let builtIn):
            guard let filter = CIFilter(name: builtIn.filterName) else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            return (filter.outputImage ?? image).cropped(to: image.extent)
        }
    }

    private static func applyLUT(_ image: CIImage, name: String) -> CIImage {
        guard let data = LUTStore.shared.latticeData(named: name), let lutSpace else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(LUTStore.dimension)
        filter.cubeData = data
        filter.colorSpace = lutSpace
        filter.extrapolate = false
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }
}
