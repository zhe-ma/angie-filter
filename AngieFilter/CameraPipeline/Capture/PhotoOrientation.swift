import AVFoundation
import CoreImage

/// Stills come back upright and unmirrored for both cameras. The front mirror is added later
/// by `FrameImageMaker`, the same way the preview shows it.
enum PhotoOrientation {
    /// The app is portrait only, so every still is tagged as a 90° rotation of the sensor.
    static func preparePortrait(_ connection: AVCaptureConnection) {
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// `CIImage(data:)` ignores the EXIF orientation unless asked.
    static func uprightImage(from data: Data) -> CIImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true])
    }
}
