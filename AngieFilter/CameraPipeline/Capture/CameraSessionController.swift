import AVFoundation
import CoreImage
import Metal
import UIKit

final class CameraSessionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let previewView: PreviewMetalView

    var onStatus: ((CameraStatus) -> Void)?
    /// The still, and the shot's ID when a Live Photo movie will follow through `onLivePhoto`.
    var onPhoto: ((UIImage, Int64?) -> Void)?
    /// Nil files mean the movie failed; the still is still usable.
    var onLivePhoto: ((Int64, LivePhotoFiles?) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "angie.camera.session")
    private let videoQueue = DispatchQueue(label: "angie.camera.video", qos: .userInteractive)
    private let photoQueue = DispatchQueue(label: "angie.camera.photo", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let parameters = Locked(RenderParameters())
    private let thumbnailTap = ThumbnailFrameTap()
    private let faceTracker = FaceTracker()
    private let trail = ZoomTrail()
    private let dolly: DollyZoom
    private let glide = ZoomGlide()
    private let watch = FaceWatch()
    private let framing = FaceFraming()
    private let motion = MotionTrail()
    private let horizon = HorizonLock()
    /// The 运镜 options the video queue reads every frame; the session queue writes them.
    private let frameMoveOptions = Locked(MoveOptions())
    /// The camera's widest horizontal view, in degrees, for the whip blur's focal length.
    private let fieldOfView = Locked<Float>(0)
    private enum Freeze {
        case none
        /// Frames shot from then on hold.
        case due(Double)
        case holding(CIImage, until: Double)
    }

    /// 急推's 定格: the video queue holds the graded picture the snap landed on for `freezeSeconds`.
    private let freeze = Locked(Freeze.none)
    private static let freezeSeconds: Double = 0.6
    /// Touched only on `sessionQueue`: the running glide is a 急推 set to freeze where it lands.
    private var freezesAfterGlide = false
    private var orbitTimer: DispatchSourceTimer?
    private let people = PersonMask()
    /// 冲击: when the last hit was fired, on the host clock.
    private let impactAt = Locked<Double?>(nil)
    /// The camera and its main lens's widest zoom, for the video queue to read the zoom from.
    private let lens = Locked<(device: AVCaptureDevice?, wide: CGFloat)>((nil, 1))
    /// 虚化's radius at the main lens's widest, in frame widths, growing as the zoom to `blurGrowth`, up to
    /// `blurMostRadius`: at 1x a soft hint, at 3x a portrait lens's.
    private static let blurRadius: CGFloat = 0.004
    private static let blurGrowth: CGFloat = 1.3
    private static let blurMostRadius: CGFloat = 0.03
    /// The last frame's uncut extent and 运镜 cut, to take a tap on the picture back to the whole frame.
    private let shownCut = Locked<(extent: CGRect?, cut: FrameCut?)>((nil, nil))
    private let captureFacing = Locked(CameraFacing.back)
    private var status = CameraStatus()
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private let previewToken = Locked(0)
    private let framePerf = PerfWindow("camera frames")
    private let loggedLook = Locked("")
    private let captions = FrameCaptionCache()
    private let modelName = PhoneModelName.marketingName(for: DeviceMachine.identifier)
    private let shutterDate = Locked("")
    private let shutterPlace = Locked("")
    private let shutterHold = Locked(HoldOrientation.portrait)
    private let liveShots = Locked<[Int64: LiveShot]>([:])
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "angie.camera.audio")
    private let recorder = Locked<VideoRecorder?>(nil)
    private let recordingHold = Locked(HoldOrientation.portrait)
    /// A 银幕 look is selected: stills are shot as ProRAW, and video as Apple Log, where the camera has them.
    private let screenSelected = Locked(false)
    /// Touched only on `sessionQueue`.
    private var liveWanted = false
    private var videoMode = false
    private var move: CameraMove?
    private var moveOptions = MoveOptions()
    /// The zoom the current take started at, when it has a 运镜.
    private var moveTakeZoom: CGFloat?
    private var lastMovePublish: CFTimeInterval = 0
    private static let movePublishInterval: CFTimeInterval = 0.25
    /// Times the main lens's widest that walking toward starts at: the face can grow to about 2.5 times its size.
    private static let zoomedStart: CGFloat = 2.5
    /// How long 急推 takes to snap in.
    private static let crashSeconds: Double = 0.3
    /// Zoom blur: the shutter's share of a 30P frame, 180°, and zoom slower than this many powers of two a second
    /// leaves no streak, so 慢推 and a walk's 希区柯克 stay sharp.
    private static let blurShutter: Double = 1.0 / 60
    private static let blurFloor: Double = 1
    private static let blurMostSpread: Double = 0.15
    /// Whip blur: turning slower than this, in radians a second, is an ordinary pan and stays sharp; the streak is
    /// kept under this share of the frame's width.
    private static let whipFloor: Double = 1.2
    private static let whipMostLength: CGFloat = 0.08
    /// Touched only on `videoQueue`.
    private var lastBlurLog: CFTimeInterval = 0
    /// Powers of two a second, for the moves to and from a take's start.
    private static let movePresetRate: Float = 3
    /// The device is on an Apple Log format; the session is off its `.photo` preset.
    private var logActive = false
    private var frameRate = VideoFrameRate.thirty
    private var audioInput: AVCaptureDeviceInput?

    override init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("This device has no Metal GPU.")
        }
        previewView = PreviewMetalView(device: metalDevice)
        dolly = DollyZoom(trail: trail)
        super.init()
        dolly.onZoom = { [weak self] factor, rate in
            self?.sessionQueue.async { self?.rampMove(to: factor, rate: rate) }
        }
        glide.onZoom = { [weak self] factor, rate in
            self?.rampMove(to: factor, rate: rate)
        }
        glide.onFinish = { [weak self] in
            guard let self else { return }
            if self.freezesAfterGlide, self.recorder.with({ $0 }) != nil {
                self.freeze.with { $0 = .due(CACurrentMediaTime()) }
            }
            self.freezesAfterGlide = false
            self.publishStatus()
        }
        watch.onSighting = { [weak self] sighting, shot, extent in
            guard let self else { return }
            if sighting?.picked == true {
                // Someone new: kept where they are now, and 希区柯克 keeps their size from here.
                self.framing.follow(true)
                self.sessionQueue.async { self.applyDolly() }
                return
            }
            // A body's size isn't a face's; to 希区柯克 it's a frame without a face.
            self.dolly.measure(sighting?.body == false ? sighting?.box : nil, shot: shot, extent: extent)
            if let sighting {
                self.framing.sight(sighting.box, body: sighting.body, extent: extent)
            }
        }
    }

    func updateRenderParameters(_ body: (inout RenderParameters) -> Void) {
        let lookID = parameters.with { value -> Look.ID in
            body(&value)
            value.frameModelName = modelName
            return value.lookID
        }
        let screen = LookLibrary.look(id: lookID).isScreen
        let changed = screenSelected.with { wanted -> Bool in
            defer { wanted = screen }
            return wanted != screen
        }
        if changed {
            sessionQueue.async { [weak self] in
                self?.applyLogVideo()
                self?.applyProRAW()
            }
        }
    }

    func requestThumbnailSource(_ completion: @escaping @Sendable (CIImage?) -> Void) {
        thumbnailTap.request(completion)
    }

    func start() {
        sessionQueue.async { [weak self] in
            self?.configureAndStart()
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            if let self, self.logActive {
                // Dual takes the same camera and sets its own format; the single session comes back on the photo preset.
                self.session.beginConfiguration()
                self.leaveLog()
                self.session.commitConfiguration()
                self.status.logVideo = false
            }
            self?.dolly.disarm()
            self?.trail.stop()
            self?.motion.stop()
            self?.glide.stop()
            self?.watch.stop()
            self?.framing.follow(false)
            if let self, self.session.isRunning {
                self.session.stopRunning()
                self.status.isRunning = false
                self.publishStatus()
            }
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func setFacing(_ facing: CameraFacing) {
        sessionQueue.async { [weak self] in
            self?.reconfigure(facing: facing)
        }
    }

    func setZoom(factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let clamped = ZoomLadderBuilder.clamped(factor, on: device)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                self.status.zoomFactor = clamped
                self.status.focalLength = ZoomLadderBuilder.focalLength(for: clamped, on: device)
                self.publishStatus()
                // Mid-take, a new framing is a new size and place to keep, and a glide leaves the zoom to the hand.
                self.glide.stop()
                self.applyMove(relock: true)
            } catch {
                self.publishFailure("变焦失败")
            }
        }
    }

    /// 运镜, in video mode only; nil is off. Picking one moves the zoom to where it starts. The move runs only during a
    /// take, from whatever zoom the shot was framed at.
    func setCameraMove(_ next: CameraMove?) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let changed = next != nil && next != self.move
            self.move = next
            self.glide.stop()
            if changed {
                self.presetMove()
            }
            self.applyMove()
        }
    }

    /// 运镜's settings for the next take; leveling and 手持感 show in the preview at once.
    func setMoveOptions(_ options: MoveOptions) {
        frameMoveOptions.with { $0 = options }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let old = self.moveOptions
            self.moveOptions = options
            let pullMoved = options.pullStart != old.pullStart && self.move == .pullOut
            let crashMoved = (options.crashOut != old.crashOut || options.crashReach != old.crashReach) && self.move == .crashIn
            if pullMoved || crashMoved {
                self.presetMove()
            }
        }
    }

    /// Zooming in starts at the main lens's widest; zooming out starts in, with room to go. 跟拍 stays put.
    private func presetMove() {
        guard let move, move.zooms, videoMode, recorder.with({ $0 }) == nil, let device else { return }
        let range = Self.moveRange(for: device, at: ZoomLadderBuilder.wideAngleFactor(for: device))
        let zoomedStart = switch move {
        case .pullOut: moveOptions.pullStart
        case .crashIn: moveOptions.crashReach
        default: Self.zoomedStart
        }
        let start = move.zoomsIn(moveOptions) ? range.lowerBound : min(range.lowerBound * zoomedStart, range.upperBound)
        rampMoveEnd(to: start)
    }

    /// The cut is in whenever 运镜 is on; mid-take the face is watched and the cut follows it. `relock` keeps the
    /// face wherever it is now, for a new framing.
    private func applyMove(relock: Bool = false) {
        let on = move != nil && videoMode && isConfigured
        let taking = on && recorder.with({ $0 }) != nil
        framing.setOn(on)
        if on {
            motion.start()
        } else if motion.isOn {
            motion.stop()
        }
        if taking, !trail.isOn, let device {
            trail.start(device)
            fieldOfView.with { $0 = device.activeFormat.videoFieldOfView }
        } else if !taking {
            trail.stop()
        }
        if taking, !watch.isOn {
            watch.start()
            framing.follow(true)
        } else if taking, relock {
            framing.follow(true)
        } else if !taking, watch.isOn {
            watch.stop()
            framing.follow(false)
        }
        applyDolly()
    }

    /// 希区柯克 follows the face only mid-take, from the zoom now, which also makes the face's size now the one kept.
    private func applyDolly() {
        guard let move, move.followsFace, videoMode, isConfigured, recorder.with({ $0 }) != nil, let device else {
            if dolly.isArmed {
                dolly.disarm()
                // The last step may not have reached the focal readout.
                publishStatus()
            }
            return
        }
        let range = Self.moveRange(for: device, at: device.videoZoomFactor)
        let strength = moveOptions.strength
        dolly.arm(device: device, range: range, zoomsIn: move.zoomsIn, strength: Double(strength))
        PerfLog.line(String(format: "dolly armed %@ at %.2f, range %.2f-%.2f, strength %.2f", move.title,
                            device.videoZoomFactor, range.lowerBound, range.upperBound, strength))
    }

    /// At the start of a take, as the options say: 慢推 in by `pushReach` times, 慢拉 out to the lens's widest,
    /// 急推 a moment later in by `crashReach` times.
    private func startGlide() {
        guard let move, move.zooms, !move.followsFace, videoMode, let device else { return }
        let from = device.videoZoomFactor
        let range = Self.moveRange(for: device, at: from)
        let to: CGFloat
        let seconds: Double
        var delay: Double = 0
        var curve = ZoomGlide.Curve.smooth
        freezesAfterGlide = false
        freeze.with { $0 = .none }
        switch move {
        case .crashIn:
            to = moveOptions.crashOut ? range.lowerBound : min(from * moveOptions.crashReach, range.upperBound)
            seconds = Self.crashSeconds
            delay = moveOptions.crashDelay
            curve = .snap
            freezesAfterGlide = moveOptions.crashFreeze
        case .pullOut:
            to = range.lowerBound
            seconds = moveOptions.glideSeconds
        default:
            to = min(from * moveOptions.pushReach, range.upperBound)
            seconds = moveOptions.glideSeconds
        }
        glide.start(from: from, to: to, over: seconds, after: delay, curve: curve, on: sessionQueue)
        PerfLog.line(String(format: "glide %@ %.2f -> %.2f over %.1fs after %.1fs", move.title, from, to, seconds, delay))
    }

    /// 环绕: a 跟拍 take shows how far round the phone has circled, four times a second.
    private func startOrbit() {
        stopOrbit()
        guard move == .follow, videoMode, let first = motion.sample(at: CACurrentMediaTime()) else { return }
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.movePublishInterval, repeating: Self.movePublishInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let now = self.motion.sample(at: CACurrentMediaTime()) else { return }
            let degrees = Int(((now.yaw - first.yaw) * 180 / .pi).rounded())
            guard degrees != self.status.orbitDegrees else { return }
            self.status.orbitDegrees = degrees
            self.publishStatus()
        }
        orbitTimer = timer
        timer.resume()
        status.orbitDegrees = 0
        publishStatus()
    }

    private func stopOrbit() {
        orbitTimer?.cancel()
        orbitTimer = nil
        if status.orbitDegrees != nil {
            status.orbitDegrees = nil
            publishStatus()
        }
    }

    /// After a take the zoom goes back to where it started, ready for the next.
    private func returnMoveZoom() {
        guard move != nil, videoMode, let start = moveTakeZoom else { return }
        moveTakeZoom = nil
        rampMoveEnd(to: start)
    }

    private func rampMoveEnd(to factor: CGFloat) {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        device.ramp(toVideoZoomFactor: factor, withRate: Self.movePresetRate)
        device.unlockForConfiguration()
        status.zoomFactor = factor
        status.focalLength = ZoomLadderBuilder.focalLength(for: factor, on: device)
        publishStatus()
    }

    private func rampMove(to factor: CGFloat, rate: Float) {
        guard dolly.isArmed || glide.isRunning, let device, (try? device.lockForConfiguration()) != nil else { return }
        device.ramp(toVideoZoomFactor: factor, withRate: rate)
        device.unlockForConfiguration()
        status.zoomFactor = factor
        status.focalLength = ZoomLadderBuilder.focalLength(for: factor, on: device)
        // The zoom moves every frame; the focal readout doesn't need to redraw the camera screen that often.
        let now = CACurrentMediaTime()
        if now - lastMovePublish >= Self.movePublishInterval {
            lastMovePublish = now
            publishStatus()
        }
    }

    /// The span of the lens `zoom` is on, up to the zoom ceiling: past a switch-over the virtual camera changes lens
    /// and the picture jumps.
    private static func moveRange(for device: AVCaptureDevice, at zoom: CGFloat) -> ClosedRange<CGFloat> {
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let lower = ([device.minAvailableVideoZoomFactor] + switches.filter { $0 <= zoom + 0.001 }).max() ?? zoom
        let ceiling = ZoomLadderBuilder.clamped(.greatestFiniteMagnitude, on: device)
        let upper = min(switches.first { $0 > zoom + 0.001 }.map { $0 * 0.98 } ?? ceiling, ceiling)
        return lower...max(lower, upper)
    }

    /// 冲击: a hit on the beat mid-take with 运镜 on, in the preview and the movie.
    func impact() {
        guard recorder.with({ $0 }) != nil, shownCut.with({ $0.cut }) != nil else { return }
        impactAt.with { $0 = CACurrentMediaTime() }
    }

    /// 运镜 follows whatever is at `point`, normalized to the picture on screen with y down: now if mid-take,
    /// otherwise from the next take's start.
    func pickSubject(atPicturePoint point: CGPoint) {
        guard let spot = shownCut.with({ shown -> CGPoint? in
            guard let extent = shown.extent, extent.width > 1, extent.height > 1 else { return nil }
            var place = CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
            if let fill = shown.cut?.fill(extent) {
                place = place.applying(fill.inverted())
            }
            return CGPoint(x: (place.x - extent.minX) / extent.width, y: (place.y - extent.minY) / extent.height)
        }) else { return }
        watch.pick(CGPoint(x: min(max(spot.x, 0), 1), y: min(max(spot.y, 0), 1)))
    }

    func focus(atDevicePoint point: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                self.publishFailure("对焦失败")
            }
        }
    }

    /// Live Photo movies carry sound when the microphone is allowed; without it they are silent.
    func setLivePhoto(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.liveWanted = on
            self.applyExtrasAskingForMicrophone(on)
        }
    }

    /// Video mode adds the microphone and turns Live Photo off; photo mode puts both back as they were.
    func setVideoMode(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoMode = on
            // Live Photo goes off before the Log format comes in, and the photo preset is back before Live Photo returns.
            if on {
                self.applyExtrasAskingForMicrophone(on)
                self.applyLogVideo()
            } else {
                self.applyLogVideo()
                self.applyExtrasAskingForMicrophone(on)
            }
            self.glide.stop()
            self.presetMove()
            self.applyMove()
        }
    }

    func setVideoFrameRate(_ rate: VideoFrameRate) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameRate = rate
            self.applyFrameRate()
        }
    }

    func startRecording(to url: URL) {
        let hold = parameters.with { $0.hold }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let lapse = self.frameRate == .lapse
            // A sped-up take would chirp; 延时 is silent.
            let sound = self.session.outputs.contains(self.audioOutput) && !lapse
                ? self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                : nil
            self.recordingHold.with { $0 = hold }
            let fps = self.device.flatMap(Self.lockedFrameRate) ?? 30
            self.recorder.with {
                $0 = VideoRecorder(url: url, audioSettings: sound, frameRate: fps,
                                   speedUp: lapse ? VideoFrameRate.lapseSpeed : 1)
            }
            // The take keeps the face at its size when it starts, or glides from the zoom then.
            self.moveTakeZoom = self.move != nil && self.videoMode ? self.device?.videoZoomFactor : nil
            self.applyMove()
            self.startGlide()
            self.startOrbit()
        }
    }

    /// 24fps in video mode when the format allows it; otherwise the format's own range.
    private func applyFrameRate() {
        guard isConfigured, let device else { return }
        let wants24 = videoMode && frameRate == .twentyFour && device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= 24 && $0.maxFrameRate >= 24
        }
        guard (try? device.lockForConfiguration()) != nil else { return }
        let duration = wants24 ? CMTime(value: 1, timescale: 24) : .invalid
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        applyStabilization()
    }

    /// Steadiest first. Cinematic modes crop in and hold frames back to smooth over them.
    private static let stabilizationModes: [AVCaptureVideoStabilizationMode] = [.cinematicExtended, .cinematic, .standard]

    /// Video mode steadies the frames the preview, 运镜 and the movie all come from; photo mode keeps them as shot, so
    /// the viewfinder doesn't lag the hand. Depends on the format, so it follows every format change; never mid-take.
    private func applyStabilization() {
        guard isConfigured, let device, recorder.with({ $0 }) == nil,
              let connection = videoOutput.connection(with: .video) else { return }
        let format = device.activeFormat
        let wanted = videoMode && connection.isVideoStabilizationSupported
            ? Self.stabilizationModes.first { format.isVideoStabilizationModeSupported($0) } ?? .off
            : .off
        guard connection.preferredVideoStabilizationMode != wanted else { return }
        connection.preferredVideoStabilizationMode = wanted
        // The active mode settles once the session has taken the change.
        sessionQueue.asyncAfter(deadline: .now() + 1) {
            PerfLog.line("single: stabilization wanted \(Self.describe(wanted)), active \(Self.describe(connection.activeVideoStabilizationMode)), format \(CaptureFormatLog.describe(format, on: device))")
        }
    }

    private static func describe(_ mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off: "off"
        case .standard: "standard"
        case .cinematic: "cinematic"
        case .cinematicExtended: "cinematicExtended"
        case .cinematicExtendedEnhanced: "cinematicExtendedEnhanced"
        case .previewOptimized: "previewOptimized"
        case .auto: "auto"
        default: "mode \(mode.rawValue)"
        }
    }

    /// The rate the device is pinned to, or nil when it is free to vary.
    private static func lockedFrameRate(_ device: AVCaptureDevice) -> Int? {
        let fastest = device.activeVideoMinFrameDuration
        guard fastest.isValid, fastest == device.activeVideoMaxFrameDuration, fastest.seconds > 0 else { return nil }
        return Int((1 / fastest.seconds).rounded())
    }

    func stopRecording(_ completion: @escaping (URL?) -> Void) {
        sessionQueue.async { [weak self] in
            let active = self?.recorder.with { recorder -> VideoRecorder? in
                defer { recorder = nil }
                return recorder
            }
            // A look picked during the take may want the other color space.
            self?.applyLogVideo()
            self?.glide.stop()
            self?.stopOrbit()
            self?.freeze.with { $0 = .none }
            self?.applyMove()
            self?.returnMoveZoom()
            guard let active else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            active.finish { url in
                DispatchQueue.main.async { completion(url) }
            }
        }
    }

    func setFlash(_ mode: FlashMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.status.flashMode = mode
            self.publishStatus()
        }
    }

    func capturePhoto() {
        let day = FrameDateText.string(from: Date())
        let place = parameters.with { $0.framePlace }
        let hold = parameters.with { $0.hold }
        shutterDate.with { $0 = day }
        shutterPlace.with { $0 = place }
        shutterHold.with { $0 = hold }
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            let settings = self.rawPixelFormat().map { AVCapturePhotoSettings(rawPixelFormatType: $0) } ?? AVCapturePhotoSettings()
            let flash = self.avFlashMode(self.status.flashMode)
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            self.captureFacing.with { $0 = self.status.facing }
            if let connection = self.photoOutput.connection(with: .video) {
                PhotoOrientation.preparePortrait(connection)
            }
            if self.photoOutput.isLivePhotoCaptureEnabled {
                settings.livePhotoMovieFileURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("capture-\(settings.uniqueID).mov")
                self.liveShots.with { $0[settings.uniqueID] = LiveShot() }
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// ProRAW only for a 银幕 look, and not for Live Photos, which ProRAW can't carry.
    private func rawPixelFormat() -> OSType? {
        guard screenSelected.with({ $0 }), photoOutput.isAppleProRAWEnabled, !photoOutput.isLivePhotoCaptureEnabled else { return nil }
        return photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
    }

    /// ProRAW is on only while a 银幕 look is selected: turning it on rebuilds the capture pipeline,
    /// and every other look keeps the photo output exactly as before.
    private func applyProRAW() {
        guard isConfigured, !logActive else { return }
        let wanted = screenSelected.with { $0 } && photoOutput.isAppleProRAWSupported
        guard photoOutput.isAppleProRAWEnabled != wanted else { return }
        let start = PerfLog.now()
        session.beginConfiguration()
        photoOutput.isAppleProRAWEnabled = wanted
        session.commitConfiguration()
        PerfLog.line("single: ProRAW \(wanted ? "on" : "off") in \(Int(PerfLog.ms(since: start)))ms")
    }

    /// Apple Log only in video mode with a 银幕 look, where the camera has a Log format. The device leaves the photo
    /// preset for that format, and the photo output can't shoot while Log is selected, so photo mode and every other
    /// look stay on the preset exactly as before. Never switched mid-take: the movie's size is fixed.
    private func applyLogVideo() {
        guard isConfigured, let device, recorder.with({ $0 }) == nil else { return }
        let format = videoMode && screenSelected.with({ $0 }) ? Self.logFormat(for: device) : nil
        guard (format != nil) != logActive else { return }
        let start = PerfLog.now()
        let zoom = device.videoZoomFactor
        defer {
            // A format change can put a virtual camera back on its widest lens.
            if device.videoZoomFactor != zoom, (try? device.lockForConfiguration()) != nil {
                device.videoZoomFactor = ZoomLadderBuilder.clamped(zoom, on: device)
                device.unlockForConfiguration()
            }
        }
        session.beginConfiguration()
        if let format, (try? device.lockForConfiguration()) != nil {
            photoOutput.isAppleProRAWEnabled = false
            session.automaticallyConfiguresCaptureDeviceForWideColor = false
            device.activeFormat = format
            device.activeColorSpace = .appleLog
            device.unlockForConfiguration()
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Self.logPixelFormat]
            logActive = true
        } else {
            leaveLog()
        }
        session.commitConfiguration()
        applyFrameRate()
        applyProRAW()
        status.logVideo = logActive
        publishStatus()
        PerfLog.line("single: Apple Log \(logActive ? "on" : "off") in \(Int(PerfLog.ms(since: start)))ms, format \(CaptureFormatLog.describe(device.activeFormat, on: device))")
    }

    /// Back to the photo preset, which picks the photo format and Display P3 again. Call inside a configuration.
    private func leaveLog() {
        guard logActive else { return }
        session.automaticallyConfiguresCaptureDeviceForWideColor = true
        session.sessionPreset = .photo
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        logActive = false
    }

    private static let logPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

    /// A Log format that frames like the photo format, around the preview's 1920 wide, and runs at 24 and 30.
    private static func logFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let photo = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let photoAspect = Double(photo.width) / Double(max(photo.height, 1))
        let candidates = device.formats.filter { format in
            format.supportedColorSpaces.contains(.appleLog)
                && CMFormatDescriptionGetMediaSubType(format.formatDescription) == logPixelFormat
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 24 && $0.maxFrameRate >= 30 }
        }
        func rank(_ format: AVCaptureDevice.Format) -> (Int, Int, Int32) {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let aspect = Double(size.width) / Double(max(size.height, 1))
            return (abs(aspect - photoAspect) < 0.01 ? 0 : 1, size.width >= 1920 ? 0 : 1, abs(size.width - 1920))
        }
        return candidates.min { rank($0) < rank($1) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder.with { $0 }?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let start = PerfLog.now()
        let renderParameters = parameters.with { $0 }
        if renderParameters.lookID != loggedLook.with({ $0 }) {
            loggedLook.with { $0 = renderParameters.lookID }
            let curve = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferLogTransferFunctionKey, nil).map { "\($0)" } ?? "none"
            PerfLog.line("preview look \(renderParameters.lookID), buffer \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer)), log curve \(curve)")
        }
        // Only Apple Log is asked for in 10 bits, so the buffer's own format says which frames are Log.
        let log = CVPixelBufferGetPixelFormatType(pixelBuffer) == Self.logPixelFormat
            ? FrameImageMaker.logSources(from: pixelBuffer, parameters: renderParameters)
            : nil
        let uncut = log?.display ?? FrameImageMaker.sourceImage(from: pixelBuffer, parameters: renderParameters)
        // 运镜 measures the whole frame, so the face's place and size don't depend on where the cut is.
        trail.noteFrame()
        let presented = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let shot = presented.isValid ? presented.seconds : CACurrentMediaTime()
        watch.offer(uncut, at: presented)
        let options = frameMoveOptions.with { $0 }
        let turn = motion.sample(at: shot)
        let hold = recorder.with({ $0 }) != nil ? recordingHold.with { $0 } : nil
        let tilt = horizon.tilt(turn, at: shot, mode: options.horizon, hold: hold)
        // A hit lands on the frames shot after the tap, however late they arrive.
        let sinceHit = impactAt.with { $0 }.map { shot - $0 }
        let hit = sinceHit.flatMap(ImpactShake.offset(after:))
        let sway = options.handheld ? HandheldSway.offset(at: shot).adding(hit) : hit
        let cut = framing.cut(for: uncut.extent, at: CACurrentMediaTime(), tilt: tilt, sway: sway)
        shownCut.with { $0 = (uncut.extent, cut) }
        var source = cut.map { FrameImageMaker.cut(uncut, to: $0) } ?? uncut
        var scene = cut.flatMap { cut in log.map { FrameImageMaker.cut($0.scene, to: cut) } } ?? log?.scene
        if let spread = zoomBlurSpread(at: presented) {
            // The zoom goes toward the middle of the whole frame, wherever the cut is.
            let middle = CGPoint(x: uncut.extent.midX, y: uncut.extent.midY)
            let center = cut?.fill(uncut.extent).map { middle.applying($0) } ?? middle
            source = FrameImageMaker.zoomBlurred(source, center: center, spread: spread)
            scene = scene.map { FrameImageMaker.zoomBlurred($0, center: center, spread: spread) }
        }
        if let whip = whipBlur(turn, at: shot, frame: uncut.extent, cut: cut) {
            source = FrameImageMaker.motionBlurred(source, length: whip.length, angle: whip.angle)
            scene = scene.map { FrameImageMaker.motionBlurred($0, length: whip.length, angle: whip.angle) }
        }
        if cut != nil, options.backgroundBlur, let mask = people.mask(offering: source) {
            let radius = backgroundBlurRadius(width: source.extent.width)
            source = FrameImageMaker.backgroundBlurred(source, people: mask, radius: radius)
            scene = scene.map { FrameImageMaker.backgroundBlurred($0, people: mask, radius: radius) }
        }
        thumbnailTap.offer(source)
        let faces = renderParameters.beauty > 0 ? faceTracker.faces(offering: source) : []
        let flash = sinceHit.map(ImpactShake.flash(after:)) ?? 0
        let graded = held(FrameImageMaker.flashed(FrameImageMaker.graded(source, scene: scene, faces: faces,
                                                                         parameters: renderParameters), amount: flash),
                          shot: shot)
        let framed = framedImage(graded, parameters: renderParameters, synchronousCaption: false)
        previewView.draw(image: framed, token: previewToken.with { $0 })
        if let active = recorder.with({ $0 }) {
            let hold = recordingHold.with { $0 }
            let recorded = hold == .portrait
                ? framed
                : framedImage(FrameImageMaker.turned(graded, hold: hold), parameters: renderParameters, synchronousCaption: true)
            active.appendVideo(recorded, at: presented)
        }
        // How long after the shot the frame got here: stabilization holds frames back.
        var perf = ["build": PerfLog.ms(since: start)]
        if presented.isValid {
            perf["age"] = (start - presented.seconds) * 1000
        }
        framePerf.add(perf)
    }

    /// 虚化 grows with the focal length, as a lens's out-of-focus blur does at the same framing, so a push in melts
    /// the background away and a pull out brings it back.
    private func backgroundBlurRadius(width: CGFloat) -> CGFloat {
        let (device, wide) = lens.with { $0 }
        let zoom = (device?.videoZoomFactor ?? wide) / max(wide, 0.01)
        return min(Self.blurRadius * pow(max(zoom, 1), Self.blurGrowth), Self.blurMostRadius) * width
    }

    /// 定格: from the first frame shot after a freezing 急推 lands, the same picture for a moment. The picture is
    /// rendered into an image of its own, so no camera buffer is held meanwhile.
    private func held(_ graded: CIImage, shot: Double) -> CIImage {
        let state = freeze.with { $0 }
        switch state {
        case .none:
            return graded
        case .due(let at):
            guard shot >= at, let still = previewView.makeImage(graded)?.cgImage else { return graded }
            let origin = graded.extent.origin
            let frozen = CIImage(cgImage: still).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
            freeze.with { $0 = .holding(frozen, until: shot + Self.freezeSeconds) }
            PerfLog.line("freeze at \(String(format: "%.2f", shot))")
            return frozen
        case .holding(let frozen, let until):
            guard shot < until else {
                freeze.with { $0 = .none }
                return graded
            }
            return frozen
        }
    }

    /// Mid-take with a 运镜, how far the zoom moved while this frame's shutter was open, past what reads as still.
    private func zoomBlurSpread(at shot: CMTime) -> CGFloat? {
        guard shot.isValid, let speed = trail.stopsPerSecond(at: shot.seconds) else { return nil }
        let fast = abs(speed) - Self.blurFloor
        guard fast > 0 else { return nil }
        let spread = min(1 - pow(2, -fast * Self.blurShutter), Self.blurMostSpread)
        let now = CACurrentMediaTime()
        if now - lastBlurLog >= 0.1 {
            lastBlurLog = now
            PerfLog.line(String(format: "zoom blur %+.1f stops/s, spread %.3f", speed, spread))
        }
        return CGFloat(speed > 0 ? spread : -spread)
    }

    /// Mid-take with a 运镜, how far the picture slid while this frame's shutter was open as the phone turned, in
    /// pixels of the cut picture, and which way; nil for an ordinary pan.
    private func whipBlur(_ turn: MotionTrail.Sample?, at shot: Double, frame extent: CGRect, cut: FrameCut?)
        -> (length: CGFloat, angle: CGFloat)? {
        guard let turn, trail.isOn else { return nil }
        let fast = hypot(turn.rate.x, turn.rate.y) - Self.whipFloor
        let view = Double(fieldOfView.with { $0 }) * .pi / 180
        guard fast > 0, view > 0 else { return nil }
        // Turning about the phone's long axis slides the picture across it; tipping, along it. The format's view
        // is across its long side, which is the portrait frame's height.
        let focal = Double(max(extent.width, extent.height)) / 2 * Double(trail.zoom(at: shot)) / tan(view / 2)
        let enlarged = cut.map { Double(extent.width / $0.size.width) } ?? 1
        let length = min(CGFloat(fast * Self.blurShutter * focal * enlarged), Self.whipMostLength * extent.width)
        let angle = CGFloat(atan2(-turn.rate.x, turn.rate.y)) - (cut?.angle ?? 0)
        let now = CACurrentMediaTime()
        if now - lastBlurLog >= 0.1 {
            lastBlurLog = now
            PerfLog.line(String(format: "whip blur %.1f rad/s, %.0f px at %.0f°", fast + Self.whipFloor, length,
                                angle * 180 / .pi))
        }
        return (length, angle)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        framePerf.tally("cameraDropped")
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        PerfLog.line("camera dropped frame: \(reason.map { "\($0)" } ?? "unknown")")
    }

    /// Photo callbacks arrive on the main thread; the still is graded on `photoQueue` so the interface keeps drawing
    /// and a slow 银幕 still can't trip the watchdog. The shot's other callbacks follow it there to keep their order.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        photoQueue.async { [weak self] in
            self?.finishPhoto(photo, error: error)
        }
    }

    private func finishPhoto(_ photo: AVCapturePhoto, error: Error?) {
        if let error {
            publishFailure(error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            publishFailure("没有拿到照片")
            return
        }
        let photoImage: CIImage
        var scene: CIImage?
        if photo.isRawPhoto {
            guard let developed = ProRAWDevelopment(data: data) else {
                publishFailure("RAW 显影失败")
                return
            }
            photoImage = developed.display
            scene = developed.scene
        } else {
            guard let image = PhotoOrientation.uprightImage(from: data) else {
                publishFailure("没有拿到照片")
                return
            }
            photoImage = image
        }
        var renderParameters = parameters.with { $0 }
        renderParameters.quality = .still
        renderParameters.orientation = .up
        renderParameters.mirrorHorizontally = captureFacing.with { $0 } == .front
        renderParameters.frameDate = shutterDate.with { $0 }
        renderParameters.framePlace = shutterPlace.with { $0 }
        renderParameters.hold = shutterHold.with { $0 }
        let start = PerfLog.now()
        let faces = renderParameters.beauty > 0
            ? FaceTracker.detect(in: FrameImageMaker.sourceImage(from: photoImage, parameters: renderParameters))
            : []
        let framed = stillPipeline(photoImage, scene: scene, faces: faces, parameters: renderParameters)
        guard let image = previewView.makeImage(framed) else {
            publishFailure("照片处理失败")
            return
        }
        if scene != nil || renderParameters.beauty > 0 {
            PerfLog.line("still graded in \(Int(PerfLog.ms(since: start)))ms, proraw \(scene != nil), faces \(faces.count)")
        }
        let id = photo.resolvedSettings.uniqueID
        let live = photo.resolvedSettings.livePhotoMovieDimensions.width > 0
            && liveShots.with { shots -> Bool in
                guard shots[id] != nil else { return false }
                shots[id]?.still = (image, renderParameters, faces)
                return true
            }
        DispatchQueue.main.async { [weak self] in
            self?.onPhoto?(image, live ? id : nil)
        }
        if live {
            renderLiveIfReady(id)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
        duration: CMTime,
        photoDisplayTime: CMTime,
        resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        photoQueue.async { [weak self] in
            self?.finishLiveMovie(outputFileURL, photoDisplayTime: photoDisplayTime, id: resolvedSettings.uniqueID, error: error)
        }
    }

    private func finishLiveMovie(_ outputFileURL: URL, photoDisplayTime: CMTime, id: Int64, error: Error?) {
        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            failLive(id)
            return
        }
        let known = liveShots.with { shots -> Bool in
            guard shots[id] != nil else { return false }
            shots[id]?.movie = (outputFileURL, photoDisplayTime)
            return true
        }
        guard known else {
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }
        renderLiveIfReady(id)
    }

    /// A shot whose still never arrived has no review screen waiting for it.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let id = resolvedSettings.uniqueID
        photoQueue.async { [weak self] in
            let orphan = self?.liveShots.with { shots -> LiveShot? in
                guard let shot = shots[id], shot.still == nil else { return nil }
                shots[id] = nil
                return shot
            }
            if let movie = orphan?.movie?.url {
                try? FileManager.default.removeItem(at: movie)
            }
        }
    }

    private func renderLiveIfReady(_ id: Int64) {
        let ready = liveShots.with { shots -> LiveShot? in
            guard let shot = shots[id], shot.still != nil, shot.movie != nil else { return nil }
            shots[id] = nil
            return shot
        }
        guard let ready, let still = ready.still, let movie = ready.movie else { return }
        let identifier = UUID().uuidString
        let folder = FileManager.default.temporaryDirectory
        let files = LivePhotoFiles(
            photo: folder.appendingPathComponent("live-\(identifier).heic"),
            movie: folder.appendingPathComponent("live-\(identifier).mov")
        )
        let parameters = still.parameters
        let faces = still.faces
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let start = PerfLog.now()
            do {
                try PhotoLibraryStore.writeLiveStill(still.image, identifier: identifier, to: files.photo)
                try await LivePhotoMovieRenderer.render(
                    source: movie.url,
                    destination: files.movie,
                    identifier: identifier,
                    stillTime: movie.stillTime
                ) { [weak self] frame in
                    self?.stillPipeline(frame, faces: faces, parameters: parameters) ?? frame
                }
                try? FileManager.default.removeItem(at: movie.url)
                PerfLog.line("live movie rendered in \(Int(PerfLog.ms(since: start)))ms")
                DispatchQueue.main.async { [weak self] in
                    self?.onLivePhoto?(id, files)
                }
            } catch {
                PerfLog.line("live movie failed: \(error)")
                try? FileManager.default.removeItem(at: movie.url)
                files.discard()
                self.failLive(id)
            }
        }
    }

    private func failLive(_ id: Int64) {
        liveShots.with { $0[id] = nil }
        DispatchQueue.main.async { [weak self] in
            self?.onLivePhoto?(id, nil)
        }
    }

    /// The still's steps from an upright, unmirrored image: mirror and crop, grade, turn for the hold, frame.
    /// `scene` is the same shot in scene light, cut the same way. `faces` are normalized to the cut image;
    /// a Live Photo's movie frames reuse its still's.
    private func stillPipeline(_ image: CIImage, scene: CIImage? = nil, faces: [FaceRegion], parameters: RenderParameters) -> CIImage {
        let source = FrameImageMaker.sourceImage(from: image, parameters: parameters)
        let sceneSource = scene.map { FrameImageMaker.sourceImage(from: $0, parameters: parameters) }
        let graded = FrameImageMaker.graded(source, scene: sceneSource, faces: faces, parameters: parameters)
        let turned = FrameImageMaker.turned(graded, hold: parameters.hold)
        return framedImage(turned, parameters: parameters, synchronousCaption: true)
    }

    private func framedImage(_ image: CIImage, parameters: RenderParameters, synchronousCaption: Bool) -> CIImage {
        guard parameters.frame.drawsBorder, let layout = FrameLayout.make(photoSize: image.extent.size, style: parameters.frame.style) else {
            return image
        }
        let caption = captionPlate(layout: layout, parameters: parameters, synchronous: synchronousCaption)
        return FrameCompositor.apply(image, settings: parameters.frame, caption: caption)
    }

    private func captionPlate(layout: FrameLayout, parameters: RenderParameters, synchronous: Bool) -> CIImage? {
        guard let key = FrameCaptionRenderer.key(layout: layout, parameters: parameters) else { return nil }
        if let cached = captions.image(for: key) { return cached }
        if synchronous || Thread.isMainThread {
            let made = Thread.isMainThread
                ? FrameCaptionRenderer.image(for: key)
                : DispatchQueue.main.sync { FrameCaptionRenderer.image(for: key) }
            if let made { captions.remember(made, for: key) }
            return made
        }
        let cache = captions
        DispatchQueue.main.async {
            guard cache.image(for: key) == nil else { return }
            if let made = FrameCaptionRenderer.image(for: key) {
                cache.remember(made, for: key)
            }
        }
        return nil
    }

    private func configureAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status.authorization = .authorized
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                self?.sessionQueue.async {
                    self?.status.authorization = allowed ? .authorized : .denied
                    if allowed {
                        self?.configureAndStart()
                    } else {
                        self?.publishStatus()
                    }
                }
            }
            return
        default:
            status.authorization = .denied
            publishStatus()
            return
        }

        if !isConfigured {
            configure(facing: .back)
            applyCaptureExtras()
            applyProRAW()
        }
        if !session.isRunning {
            applyLogVideo()
            // Dual may have held the same camera at its own rate.
            applyFrameRate()
            previewToken.with { $0 = previewView.claimDrawer() }
            session.startRunning()
            applyMove()
        }
        status.isRunning = session.isRunning
        publishStatus()
    }

    private func reconfigure(facing: CameraFacing) {
        session.beginConfiguration()
        leaveLog()
        status.logVideo = false
        for input in session.inputs where input !== audioInput {
            session.removeInput(input)
        }
        guard let next = Self.device(for: facing),
              let input = try? AVCaptureDeviceInput(device: next),
              session.canAddInput(input) else {
            session.commitConfiguration()
            publishFailure("无法切换摄像头")
            return
        }
        session.addInput(input)
        device = next
        lens.with { $0 = (next, ZoomLadderBuilder.wideAngleFactor(for: next)) }
        faceTracker.reset()
        people.reset()
        applyInitialZoom(on: next)
        status.facing = facing
        parameters.with { $0.orientation = Self.orientation(for: facing) }
        session.commitConfiguration()
        applyCaptureExtras()
        applyLogVideo()
        applyProRAW()
        glide.stop()
        presetMove()
        applyMove()
        PerfLog.line("single: format \(CaptureFormatLog.describe(next.activeFormat, on: next))")
    }

    private func applyExtrasAskingForMicrophone(_ wantsSound: Bool) {
        guard wantsSound, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            applyCaptureExtras()
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
            self?.sessionQueue.async { self?.applyCaptureExtras() }
        }
    }

    /// The microphone, the audio output, and Live Photo, for the current mode.
    /// Needs the session's inputs and preset in place: Live Photo support is only known once the output is connected.
    private func applyCaptureExtras() {
        guard isConfigured else { return }
        let wantsSound = (liveWanted || videoMode) && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        session.beginConfiguration()
        if wantsSound, audioInput == nil,
           let microphone = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(input) {
            session.addInput(input)
            audioInput = input
        } else if !wantsSound, let input = audioInput {
            session.removeInput(input)
            audioInput = nil
        }
        let wantsAudioOutput = videoMode && audioInput != nil
        let hasAudioOutput = session.outputs.contains(audioOutput)
        if wantsAudioOutput, !hasAudioOutput, session.canAddOutput(audioOutput) {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            session.addOutput(audioOutput)
        } else if !wantsAudioOutput, hasAudioOutput {
            session.removeOutput(audioOutput)
        }
        let supported = photoOutput.isLivePhotoCaptureSupported
        photoOutput.isLivePhotoCaptureEnabled = liveWanted && !videoMode && supported
        session.commitConfiguration()
        applyFrameRate()
        status.liveSupported = supported
        status.liveOn = photoOutput.isLivePhotoCaptureEnabled
        publishStatus()
    }

    private func configure(facing: CameraFacing) {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let camera = Self.device(for: facing),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            status.hasCamera = false
            session.commitConfiguration()
            publishStatus()
            return
        }
        session.addInput(input)
        device = camera
        lens.with { $0 = (camera, ZoomLadderBuilder.wideAngleFactor(for: camera)) }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        applyInitialZoom(on: camera)
        status.facing = facing
        status.hasCamera = true
        parameters.with { $0.orientation = Self.orientation(for: facing) }
        session.commitConfiguration()
        isConfigured = true
        PerfLog.line("single: format \(CaptureFormatLog.describe(camera.activeFormat, on: camera))")
    }

    private func applyInitialZoom(on device: AVCaptureDevice) {
        let stops = ZoomLadderBuilder.stops(for: device)
        let factor = ZoomLadderBuilder.clamped(ZoomLadderBuilder.wideAngleFactor(for: device), on: device)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }
        status.zoomStops = stops
        status.zoomFactor = factor
        status.focalLength = ZoomLadderBuilder.focalLength(for: factor, on: device)
        PerfLog.line(String(format: "zoom stops %@ (main %.0fmm)",
                            stops.map(\.title).joined(separator: " "), ZoomLadderBuilder.mainFocalLength(for: device)))
    }

    private func avFlashMode(_ mode: FlashMode) -> AVCaptureDevice.FlashMode {
        switch mode {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
    }

    private func publishStatus() {
        let snapshot = status
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(snapshot)
        }
    }

    private func publishFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }

    private static func device(for facing: CameraFacing) -> AVCaptureDevice? {
        if facing == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
        for type in types {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return nil
    }

    private static func orientation(for facing: CameraFacing) -> CGImagePropertyOrientation {
        facing == .front ? .leftMirrored : .right
    }
}

/// The still and the movie finish in either order; the movie is rendered once both are in.
private struct LiveShot {
    var still: (image: UIImage, parameters: RenderParameters, faces: [FaceRegion])?
    var movie: (url: URL, stillTime: CMTime)?
}
