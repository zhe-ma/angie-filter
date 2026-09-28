import CoreImage
import Foundation

/// Samples a 512×512 LUT the same way the 8×8 / 64³ grid shader does.
/// Blue 0 is the top-left tile of the PNG. `sample` here takes that top-left origin.
enum LUTImageGrader {
    private static let kernel: CIKernel? = CIKernel(source: """
    kernel vec4 lut8x8(sampler image, sampler lut) {
        vec4 color = sample(image, samplerCoord(image));
        color = clamp(color, 0.0, 1.0);
        float blue = color.b * 63.0;
        float slice1 = floor(blue);
        float slice2 = ceil(blue);

        float row1 = floor(slice1 / 8.0);
        float column1 = slice1 - row1 * 8.0;
        float x1 = column1 / 8.0 + 0.5 / 512.0 + (1.0 / 8.0 - 1.0 / 512.0) * color.r;
        float y1 = row1 / 8.0 + 0.5 / 512.0 + (1.0 / 8.0 - 1.0 / 512.0) * color.g;

        float row2 = floor(slice2 / 8.0);
        float column2 = slice2 - row2 * 8.0;
        float x2 = column2 / 8.0 + 0.5 / 512.0 + (1.0 / 8.0 - 1.0 / 512.0) * color.r;
        float y2 = row2 / 8.0 + 0.5 / 512.0 + (1.0 / 8.0 - 1.0 / 512.0) * color.g;

        vec4 sample1 = sample(lut, vec2(x1, y1) * 512.0);
        vec4 sample2 = sample(lut, vec2(x2, y2) * 512.0);
        vec3 graded = mix(sample1.rgb, sample2.rgb, fract(blue));
        return vec4(graded, color.a);
    }
    """)

    static func apply(_ image: CIImage, grade: LUTImageGrade) -> CIImage {
        if let kernel, let lut = LUTImageStore.shared.image(named: grade.imageName) {
            let extent = image.extent
            if let graded = kernel.apply(
                extent: extent,
                roiCallback: { index, rect in
                    index == 0 ? rect : lut.extent
                },
                arguments: [image, lut]
            ) {
                return graded.cropped(to: extent)
            }
        }
        return applyLattice(image, name: grade.imageName)
    }

    /// Same 8×8 grid, sampled once into a 64³ cube when the kernel is unavailable.
    private static func applyLattice(_ image: CIImage, name: String) -> CIImage {
        guard let data = LUTImageStore.shared.latticeData(named: name),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else {
            return image
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(LUTImageStore.latticeDimension, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(CGColorSpace(name: CGColorSpace.displayP3), forKey: "inputColorSpace")
        filter.setValue(false, forKey: "inputExtrapolate")
        return (filter.outputImage ?? image).cropped(to: image.extent)
    }
}
