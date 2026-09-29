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

/// How the phone is held. The interface stays portrait; icons and saved photos follow this.
enum HoldOrientation: Equatable, Sendable {
    case portrait
    /// Top of the phone points right.
    case landscapeRight
    /// Top of the phone points left.
    case landscapeLeft
    case upsideDown

    /// Device roll in radians, positive when the top leans right. Matches `atan2(gravity.x, -gravity.y)`.
    var angle: Double {
        switch self {
        case .portrait: return 0
        case .landscapeRight: return .pi / 2
        case .landscapeLeft: return -.pi / 2
        case .upsideDown: return .pi
        }
    }

    var isLandscape: Bool {
        self == .landscapeRight || self == .landscapeLeft
    }

    static func nearest(to angle: Double) -> HoldOrientation {
        let all: [HoldOrientation] = [.portrait, .landscapeRight, .landscapeLeft, .upsideDown]
        return all.min { distance($0.angle, angle) < distance($1.angle, angle) } ?? .portrait
    }

    /// Smallest absolute difference between two angles, in radians.
    static func distance(_ a: Double, _ b: Double) -> Double {
        abs(normalized(a - b))
    }

    /// Wraps into (-π, π].
    static func normalized(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if value > .pi { value -= 2 * .pi }
        if value <= -.pi { value += 2 * .pi }
        return value
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

enum CaptureMode: String, CaseIterable, Identifiable, Sendable {
    case photo = "照片"
    case video = "录像"

    var id: Self { self }
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
    /// The current camera and preset can record a Live Photo movie. Never true for dual.
    var liveSupported = false
    var liveOn = false
}
