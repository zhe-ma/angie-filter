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
/// 延时 shoots at 30 and keeps one frame in `lapseSpeed`, played back at 30; single camera only, and silent.
enum VideoFrameRate: Int, Sendable {
    case thirty = 30
    case twentyFour = 24
    case lapse = 1

    static let lapseSpeed = 6

    var label: String {
        switch self {
        case .thirty, .twentyFour: "\(rawValue)P"
        case .lapse: "延时"
        }
    }

    func next(lapseAllowed: Bool) -> VideoFrameRate {
        switch self {
        case .thirty: .twentyFour
        case .twentyFour: lapseAllowed ? .lapse : .thirty
        case .lapse: .thirty
        }
    }
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
    /// Snaps in on the middle of the frame a moment into the take.
    case crashIn
    /// Leaves the zoom alone: only the cut, following the face, leveling and swaying as the options say.
    case follow

    var id: Self { self }

    var title: String {
        switch self {
        case .dollyAway: "向后走"
        case .dollyToward: "向前走"
        case .pushIn: "慢推"
        case .pullOut: "慢拉"
        case .crashIn: "急推"
        case .follow: "跟拍"
        }
    }

    /// 急推 reads 急拉 when set to snap out.
    func title(_ options: MoveOptions) -> String {
        self == .crashIn && options.crashOut ? "急拉" : title
    }

    /// Whether the zoom goes in during the take, as the options have it.
    func zoomsIn(_ options: MoveOptions) -> Bool {
        self == .crashIn ? !options.crashOut : zoomsIn
    }

    func hint(_ options: MoveOptions) -> String {
        switch self {
        case .dollyAway: "希区柯克·向后走：录制时往后退，人物大小不变"
        case .dollyToward: "希区柯克·向前走：录制时往前走，人物大小不变"
        case .pushIn: "慢推：开始录制后 \(options.glideSecondsText) 推近到 \(MoveOptions.times(options.pushReach))"
        case .pullOut: "慢拉：从 \(MoveOptions.times(options.pullStart)) 开始，录制后 \(options.glideSecondsText) 拉远到最广"
        case .crashIn:
            (options.crashOut
                ? "急拉：从 \(MoveOptions.times(options.crashReach)) 开始，录制 \(MoveOptions.seconds(options.crashDelay)) 后猛拉到最广"
                : "急推：开始录制 \(MoveOptions.seconds(options.crashDelay)) 后猛推到 \(MoveOptions.times(options.crashReach))")
                + (options.crashFreeze ? "，停住定格" : "")
        case .follow: "跟拍：变焦不动，画面跟着人脸，可配锁平和手持感"
        }
    }

    /// 希区柯克: the zoom follows the distance to the face.
    var followsFace: Bool { self == .dollyAway || self == .dollyToward }

    var zoomsIn: Bool { self == .dollyAway || self == .pushIn || self == .crashIn }

    /// Everything but 跟拍 moves the zoom, and so has a zoom to start from.
    var zooms: Bool { self != .follow }
}

/// What the cut does about the phone's roll while 运镜 is on.
enum HorizonMode: String, CaseIterable, Sendable {
    case off
    /// Keeps the horizon level with the way the phone is held.
    case level
    /// Lets the phone turn, but evens the turn out into a steady one.
    case smooth

    var label: String {
        switch self {
        case .off: "水平"
        case .level: "锁平"
        case .smooth: "匀转"
        }
    }

    var hint: String {
        switch self {
        case .off: "不锁水平"
        case .level: "锁平：手歪了画面也保持水平，最多纠正约 10°"
        case .smooth: "匀转：跟着手转，但转得匀，抖动抹掉"
        }
    }

    var next: HorizonMode {
        let cases = Self.allCases
        return cases[(cases.firstIndex(of: self)! + 1) % cases.count]
    }
}

/// The settings each 运镜 takes, kept on the phone. Take effect at the next take.
struct MoveOptions: Equatable, Sendable {
    static let strengthRange: ClosedRange<Float> = 0.3...1.5
    static let glideSecondsSteps: [Double] = [3, 6, 10]
    static let pushReachSteps: [CGFloat] = [1.5, 2, 3]
    static let pullStartSteps: [CGFloat] = [1.5, 2.5, 4]
    static let crashDelaySteps: [Double] = [0.5, 1, 2]
    static let crashReachSteps: [CGFloat] = [2, 3, 4]

    /// 希区柯克: 1 holds the face's size.
    var strength: Float = 1
    /// 慢推 / 慢拉.
    var glideSeconds: Double = 6
    /// Times its start that 慢推 ends at.
    var pushReach: CGFloat = 2
    /// Times the main lens's widest that 慢拉 starts at.
    var pullStart: CGFloat = 2.5
    /// 急推: how long into the take, and how many times in; out instead starts that many times in and snaps out to
    /// the widest, 急拉. Freezing holds the frame it lands on for a moment.
    var crashDelay: Double = 1
    var crashReach: CGFloat = 3
    var crashOut = false
    var crashFreeze = false
    var horizon = HorizonMode.off
    /// A slow drift in place, like a camera held by hand.
    var handheld = false
    /// Blurs what's behind people, more the longer the focal length, as a big sensor would.
    var backgroundBlur = false

    var glideSecondsText: String { Self.seconds(glideSeconds) }

    /// 急推's chip: in by each reach, then out by each.
    var crashText: String { (crashOut ? "拉 " : "推 ") + Self.times(crashReach) }

    mutating func cycleCrash() {
        let steps = Self.crashReachSteps
        if let next = steps.first(where: { $0 > crashReach }) {
            crashReach = next
        } else {
            crashReach = steps[0]
            crashOut.toggle()
        }
    }

    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? "\(Int(value)) 秒" : String(format: "%.1f 秒", value)
    }

    static func times(_ value: CGFloat) -> String {
        value == value.rounded() ? "\(Int(value)) 倍" : String(format: "%.1f 倍", Double(value))
    }

    /// The step after `value`, back to the first after the last.
    static func cycle<Value: Comparable>(_ value: Value, in steps: [Value]) -> Value {
        guard let next = steps.first(where: { $0 > value }) else { return steps[0] }
        return next
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
    /// The current camera and preset can record a Live Photo movie. Never true for dual.
    var liveSupported = false
    var liveOn = false
    /// Video mode with a 银幕 look is capturing Apple Log. Single camera only.
    var logVideo = false
    /// Mid-take with 跟拍: degrees the phone has turned about the vertical since the take started, signed by the way
    /// it went.
    var orbitDegrees: Int?
}
