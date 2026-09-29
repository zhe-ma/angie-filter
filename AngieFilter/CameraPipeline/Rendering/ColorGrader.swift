import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The color step. Every LUT goes through `CIColorCubeWithColorSpace`; built-in looks call their Core Image filter.
enum ColorGrader {
    /// The LUTs were made on sRGB images. Core Image converts the P3 working space in and out.
    private static let lutSpace = CGColorSpace(name: CGColorSpace.sRGB)

    static func apply(_ image: CIImage, grade: LookGrade, quality: RenderQuality) -> CIImage {
        switch grade {
        case .none:
            return image
        case .lut(let lut):
            return self.lut(image, name: lut.imageName, quality: quality)
        case .builtIn(let builtIn):
            guard let filter = CIFilter(name: builtIn.filterName) else { return image }
            filter.setValue(image, forKey: kCIInputImageKey)
            return (filter.outputImage ?? image).cropped(to: image.extent)
        case .effect(let effect):
            return EffectChain.apply(image, grade: effect, quality: quality)
        }
    }

    /// A nil or missing name returns the image unchanged. Thumbnails use the 22³ cube.
    static func lut(_ image: CIImage, name: String?, quality: RenderQuality) -> CIImage {
        guard let name, let lutSpace else { return image }
        let small = quality == .thumbnail
        let data = small ? LUTStore.shared.smallLatticeData(named: name) : LUTStore.shared.latticeData(named: name)
        guard let data else { return image }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(small ? LUTStore.smallDimension : LUTStore.dimension)
        filter.cubeData = data
        filter.colorSpace = lutSpace
        filter.extrapolate = false
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }
}
