import CoreImage
import Foundation

/// Lampa's automatic black and white points, Neutral profile: a 256-bin RGB histogram of the
/// gamma-encoded Display P3 image, a black and white search, then five points into `CIToneCurve`.
/// Runs once per rendered frame on a copy no longer than 256 pixels.
enum AutoLevels {
    private static let binCount = 256
    private static let blackPointIntensity: Float = 0.2
    private static let whitePointIntensity: Float = 0.25

    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any,
        .cacheIntermediates: false
    ])

    static func apply(_ image: CIImage) -> CIImage {
        guard let histogram = histogram(of: image) else { return image }
        let b0 = blackCandidate(histogram)
        let w0 = whiteCandidate(histogram)
        let black = max(0, b0 * (1 - blackPointIntensity))
        let white = min(1, w0 + whitePointIntensity * (1 - w0))
        let span = white - black
        guard span > 0.05, black > 0.001 || white < 0.999 else { return image }
        let x = [black, black + 0.25 * span, black + 0.5 * span, black + 0.75 * span, white]
        let y: [Float] = [0, 0.25, 0.5, 0.75, 1]
        var parameters: [String: Any] = [:]
        for index in 0..<5 {
            parameters["inputPoint\(index)"] = CIVector(x: CGFloat(x[index]), y: CGFloat(y[index]))
        }
        return image.applyingFilter("CIToneCurve", parameters: parameters).cropped(to: image.extent)
    }

    /// H[i] = 100 × (R[i] + G[i] + B[i]) / 3, in percent of pixels.
    private static func histogram(of image: CIImage) -> [Float]? {
        let extent = image.extent
        let longEdge = max(extent.width, extent.height)
        guard longEdge > 1 else { return nil }
        let scale = min(1, 256 / longEdge)
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).applyingFilter("CIColorClamp")
        let bins = small.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: small.extent),
            "inputCount": binCount,
            "inputScale": 1
        ])
        var pixels = [Float](repeating: 0, count: binCount * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(
                bins,
                toBitmap: buffer.baseAddress!,
                rowBytes: binCount * 4 * MemoryLayout<Float>.size,
                bounds: CGRect(x: 0, y: 0, width: binCount, height: 1),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return (0..<binCount).map { index in
            100 * (pixels[index * 4] + pixels[index * 4 + 1] + pixels[index * 4 + 2]) / 3
        }
    }

    /// From the dark end: a bin above 0.001 once the running sum reaches 0.01, then the next bin
    /// above 0.0001 and at most 7 times smaller. No hit gives 0.
    private static func blackCandidate(_ histogram: [Float]) -> Float {
        guard let index = search(histogram, threshold: 0.01) else { return 0 }
        return min(Float(index) / Float(binCount), 0.25)
    }

    /// The same search from the bright end with a running sum of 0.03. No hit gives 1.
    private static func whiteCandidate(_ histogram: [Float]) -> Float {
        guard let index = search(histogram.reversed(), threshold: 0.03) else { return 1 }
        return max(1 - Float(index) / Float(binCount), 0.65)
    }

    private static func search(_ bins: [Float], threshold: Float) -> Int? {
        var sum: Float = 0
        for index in 0..<(bins.count - 1) {
            sum += bins[index]
            guard bins[index] > 0.001, sum >= threshold else { continue }
            sum = 0
            let next = bins[index + 1]
            if next > 0.0001, bins[index] / next <= 7 {
                return index
            }
        }
        return nil
    }
}
