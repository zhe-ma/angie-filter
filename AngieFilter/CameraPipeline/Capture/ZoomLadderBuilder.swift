import AVFoundation
import CoreGraphics

/// Zoom stops labeled in 35mm-equivalent focal lengths: every physical lens, plus the classic
/// street, reportage, standard, and portrait lengths that fall between them.
enum ZoomLadderBuilder {
    static let displayCeiling: CGFloat = 5
    static let recommendedFocalLengths: [CGFloat] = [28, 35, 50, 85]
    /// A preset this close to a lens is dropped in favor of the lens.
    private static let lensSnap: CGFloat = 0.1
    private static let frontLongestPreset: CGFloat = 35

    static func stops(for device: AVCaptureDevice, longestPreset: CGFloat = .infinity) -> [ZoomStop] {
        let wide = wideAngleFactor(for: device)
        let main = mainFocalLength(for: device)
        let ceiling = min(device.maxAvailableVideoZoomFactor, wide * displayCeiling)
        var lenses = [device.minAvailableVideoZoomFactor]
        lenses.append(contentsOf: device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) })
        var stops = Array(Set(lenses.filter { $0 <= ceiling + 0.01 })).map { factor in
            ZoomStop(factor: factor, focalLength: main * factor / wide)
        }
        let longest = device.position == .front ? min(longestPreset, frontLongestPreset) : longestPreset
        for focal in recommendedFocalLengths where focal <= longest {
            let factor = wide * focal / main
            guard factor >= device.minAvailableVideoZoomFactor, factor <= ceiling + 0.01 else { continue }
            guard !stops.contains(where: { abs($0.focalLength - focal) / focal < lensSnap }) else { continue }
            stops.append(ZoomStop(factor: factor, focalLength: focal))
        }
        return stops.sorted { $0.factor < $1.factor }
    }

    static func wideAngleFactor(for device: AVCaptureDevice) -> CGFloat {
        if let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return CGFloat(truncating: first)
        }
        return max(device.minAvailableVideoZoomFactor, 1)
    }

    /// The main camera's 35mm-equivalent focal length, from its diagonal field of view on a 4:3 sensor.
    /// iPhone mains are sold as 24 or 26mm; a result within 2mm snaps to the nearer of those.
    static func mainFocalLength(for device: AVCaptureDevice) -> CGFloat {
        let lens = device.constituentDevices.first { $0.deviceType == .builtInWideAngleCamera } ?? device
        let fov = CGFloat(lens.activeFormat.videoFieldOfView)
        guard fov > 10, fov < 170 else { return 26 }
        let halfDiagonal = tan(fov * .pi / 360) * 1.25
        let focal = 21.63 / halfDiagonal
        let nearest: CGFloat = abs(focal - 24) <= abs(focal - 26) ? 24 : 26
        return abs(nearest - focal) <= 2 ? nearest : focal.rounded()
    }

    static func clamped(_ factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        let wide = wideAngleFactor(for: device)
        let ceiling = min(device.maxAvailableVideoZoomFactor, wide * displayCeiling)
        return min(max(factor, device.minAvailableVideoZoomFactor), ceiling)
    }

    static func focalLength(for factor: CGFloat, on device: AVCaptureDevice) -> CGFloat {
        mainFocalLength(for: device) * factor / wideAngleFactor(for: device)
    }
}
