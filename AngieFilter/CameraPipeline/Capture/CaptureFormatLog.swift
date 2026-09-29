import AVFoundation

/// One line per active format, so the single and dual sessions can be compared in the Debug console.
enum CaptureFormatLog {
    static func describe(_ format: AVCaptureDevice.Format, on device: AVCaptureDevice) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let rates = format.videoSupportedFrameRateRanges
        let minRate = Int(rates.map(\.minFrameRate).min() ?? 0)
        let maxRate = Int(rates.map(\.maxFrameRate).max() ?? 0)
        let slowest = Int((1 / max(device.activeVideoMaxFrameDuration.seconds, 0.001)).rounded())
        let binned = format.isVideoBinned ? "yes" : "no"
        let hdr = format.isVideoHDRSupported ? (device.isVideoHDREnabled ? "on" : "off") : "n/a"
        let pixels = fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription))
        // AVCaptureColorSpace raw values: 0 sRGB, 1 P3, 2 HLG, 3 Apple Log.
        let color = device.activeColorSpace.rawValue
        return "\(size.width)x\(size.height) \(pixels) binned \(binned) hdr \(hdr) fps \(minRate)-\(maxRate) (slowest \(slowest)) color \(color)"
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        var text = ""
        for shift: UInt32 in [24, 16, 8, 0] {
            let byte = UInt8(truncatingIfNeeded: code >> shift)
            text.append(Character(Unicode.Scalar(byte)))
        }
        return text
    }
}
