import CoreGraphics

enum CameraFacing: String, Sendable {
    case back
    case front
}

enum FlashMode: String, CaseIterable, Sendable {
    case off
    case on
    case auto

    func next() -> FlashMode {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self) ?? 0
        return cases[(index + 1) % cases.count]
    }
}

enum CameraAuthorization: Sendable {
    case unknown
    case authorized
    case denied
}

struct ZoomStop: Identifiable, Equatable, Sendable {
    let factor: CGFloat
    /// 35mm-equivalent focal length in millimeters.
    let focalLength: CGFloat

    var id: CGFloat { factor }

    var title: String {
        String(Int(focalLength.rounded()))
    }
}

struct CameraStatus: Equatable, Sendable {
    var authorization: CameraAuthorization = .unknown
    var isRunning = false
    var facing: CameraFacing = .back
    var flashMode: FlashMode = .off
    var aspectRatio: AspectRatio = .threeFour
    var zoomFactor: CGFloat = 1
    var focalLength: CGFloat = 24
    var zoomStops: [ZoomStop] = []
    var hasCamera = true
}
