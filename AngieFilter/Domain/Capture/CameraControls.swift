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

/// Video mode only. 24 locks both frame durations, so it never slows down in low light; 30 keeps each session's own range.
enum VideoFrameRate: Int, Sendable {
    case thirty = 30
    case twentyFour = 24

    var label: String { "\(rawValue)P" }

    var next: VideoFrameRate { self == .thirty ? .twentyFour : .thirty }
}

/// 运镜: what the zoom does during a single-camera take. Each starts where the move has room and only goes one way.
enum CameraMove: String, CaseIterable, Identifiable, Sendable {
    /// 希区柯克, walking away from the face: starts at the lens's widest and zooms in.
    case dollyAway
    /// 希区柯克, walking toward the face: starts zoomed in and zooms out.
    case dollyToward
    /// Eases in on the middle of the frame over a few seconds.
    case pushIn
    /// Eases out to the widest over a few seconds.
    case pullOut

    var id: Self { self }

    var title: String {
        switch self {
        case .dollyAway: "向后走"
        case .dollyToward: "向前走"
        case .pushIn: "慢推"
        case .pullOut: "慢拉"
        }
    }

    var hint: String {
        switch self {
        case .dollyAway: "希区柯克·向后走：录制时往后退，人物大小不变"
        case .dollyToward: "希区柯克·向前走：录制时往前走，人物大小不变"
        case .pushIn: "慢推：开始录制后 6 秒推近到 2 倍"
        case .pullOut: "慢拉：开始录制后 6 秒拉远到最广"
        }
    }

    /// 希区柯克: the zoom follows the distance to the face.
    var followsFace: Bool { self == .dollyAway || self == .dollyToward }

    var zoomsIn: Bool { self == .dollyAway || self == .pushIn }
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
    /// Video mode with a 银幕 look is capturing Apple Log. Single camera only.
    var logVideo = false
}
