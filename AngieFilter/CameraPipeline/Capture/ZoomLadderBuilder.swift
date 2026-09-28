import AVFoundation
import CoreGraphics

enum ZoomLadderBuilder {
    static let displayCeiling: CGFloat = 5

    static func stops(for device: AVCaptureDevice) -> [ZoomStop] {
        let wide = wideAngleFactor(for: device)
        let ceiling = min(device.maxAvailableVideoZoomFactor, wide * displayCeiling)
        var factors = [device.minAvailableVideoZoomFactor]
        factors.append(contentsOf: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) })
        let unique = Array(Set(factors.filter { $0 <= ceiling + 0.01 })).sorted()
        return unique.map { factor in
            ZoomStop(factor: factor, display: factor / wide)
        }
    }

    static func wideAngleFactor(for device: AVCaptureDevice) -> CGFloat {
        if let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(truncating: first)
        }
        return max(device.minAvailableVideoZoomFactor, 1)
    }

    static func clamped(_ factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        let wide = wideAngleFactor(for: device)
        let ceiling = min(device.maxAvailableVideoZoomFactor, wide * displayCeiling)
        return min(max(factor, device.minAvailableVideoZoomFactor), ceiling)
    }

    static func displayZoom(for factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        factor / wideAngleFactor(for: device)
    }
}
