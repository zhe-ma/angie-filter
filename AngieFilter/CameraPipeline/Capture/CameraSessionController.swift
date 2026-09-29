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
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let parameters = Locked(RenderParameters())
    private let thumbnailTap = ThumbnailFrameTap()
    private let faceTracker = FaceTracker()
    private let dolly = DollyZoom()
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
    private var dollyWanted = false
    private var lastDollyPublish: CFTimeInterval = 0
    private static let dollyPublishInterval: CFTimeInterval = 0.25
    /// Times the lens's widest zoom a 希区柯克 take starts from. The 1760-wide preview buffer still comes from more
    /// sensor pixels than it has at this crop, so nothing softens.
    private static let dollyHeadroom: CGFloat = 1.4
    /// The device is on an Apple Log format; the session is off its `.photo` preset.
    private var logActive = false
    private var frameRate = VideoFrameRate.thirty
    private var audioInput: AVCaptureDeviceInput?

    override init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("This device has no Metal GPU.")
        }
        previewView = PreviewMetalView(device: metalDevice)
        super.init()
        dolly.onZoom = { [weak self] factor, rate in
            self?.sessionQueue.async { self?.rampDolly(to: factor, rate: rate) }
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
                // A new framing is a new size to keep.
                self.applyDolly()
            } catch {
                self.publishFailure("变焦失败")
            }
        }
    }

    /// 希区柯克变焦, in video mode only.
    func setDollyZoom(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.dollyWanted = on
            if on {
                self.makeDollyHeadroom()
            }
            self.applyDolly()
        }
    }

    /// At the bottom of the lens there's nothing to zoom out to when the phone comes closer, so it starts a little in.
    private func makeDollyHeadroom() {
        guard videoMode, let device else { return }
        let range = Self.dollyRange(for: device)
        let start = min(range.lowerBound * Self.dollyHeadroom, range.upperBound)
        guard device.videoZoomFactor < start * 0.97, (try? device.lockForConfiguration()) != nil else { return }
        device.videoZoomFactor = start
        device.unlockForConfiguration()
        status.zoomFactor = start
        status.focalLength = ZoomLadderBuilder.focalLength(for: start, on: device)
        publishStatus()
    }

    /// Arms from the current zoom, which also makes the face's size now the one kept.
    private func applyDolly() {
        guard dollyWanted, videoMode, isConfigured, let device else {
            if dolly.isArmed {
                dolly.disarm()
                // The last step may not have reached the focal readout.
                publishStatus()
            }
            return
        }
        let range = Self.dollyRange(for: device)
        dolly.arm(device: device, range: range)
        PerfLog.line(String(format: "dolly armed at %.2f, range %.2f-%.2f", device.videoZoomFactor, range.lowerBound, range.upperBound))
    }

    private func rampDolly(to factor: CGFloat, rate: Float) {
        guard dolly.isArmed, let device, (try? device.lockForConfiguration()) != nil else { return }
        device.ramp(toVideoZoomFactor: factor, withRate: rate)
        device.unlockForConfiguration()
        status.zoomFactor = factor
        status.focalLength = ZoomLadderBuilder.focalLength(for: factor, on: device)
        // The zoom moves every frame; the focal readout doesn't need to redraw the camera screen that often.
        let now = CACurrentMediaTime()
        if now - lastDollyPublish >= Self.dollyPublishInterval {
            lastDollyPublish = now
            publishStatus()
        }
    }

    /// The span of the lens the zoom is on now, up to the zoom ceiling: past a switch-over the virtual camera changes lens
    /// and the picture jumps.
    private static func dollyRange(for device: AVCaptureDevice) -> ClosedRange<CGFloat> {
        let zoom = device.videoZoomFactor
        let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let lower = ([device.minAvailableVideoZoomFactor] + switches.filter { $0 <= zoom + 0.001 }).max() ?? zoom
        let ceiling = ZoomLadderBuilder.clamped(.greatestFiniteMagnitude, on: device)
        let upper = min(switches.first { $0 > zoom + 0.001 }.map { $0 * 0.98 } ?? ceiling, ceiling)
        return lower...max(lower, upper)
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
            self.applyDolly()
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
            let sound = self.session.outputs.contains(self.audioOutput)
                ? self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                : nil
            self.recordingHold.with { $0 = hold }
            let fps = self.device.flatMap(Self.lockedFrameRate) ?? 30
            self.recorder.with { $0 = VideoRecorder(url: url, audioSettings: sound, frameRate: fps) }
            // The take keeps the face at its size when it starts.
            self.applyDolly()
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
        let source = log?.display ?? FrameImageMaker.sourceImage(from: pixelBuffer, parameters: renderParameters)
        thumbnailTap.offer(source)
        dolly.offer(source, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let faces = renderParameters.beauty > 0 ? faceTracker.faces(offering: source) : []
        let graded = FrameImageMaker.graded(source, scene: log?.scene, faces: faces, parameters: renderParameters)
        let framed = framedImage(graded, parameters: renderParameters, synchronousCaption: false)
        previewView.draw(image: framed, token: previewToken.with { $0 })
        if let active = recorder.with({ $0 }) {
            let hold = recordingHold.with { $0 }
            let recorded = hold == .portrait
                ? framed
                : framedImage(FrameImageMaker.turned(graded, hold: hold), parameters: renderParameters, synchronousCaption: true)
            active.appendVideo(recorded, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        framePerf.add(["build": PerfLog.ms(since: start)])
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        framePerf.tally("cameraDropped")
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        PerfLog.line("camera dropped frame: \(reason.map { "\($0)" } ?? "unknown")")
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
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
        let id = resolvedSettings.uniqueID
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
        let orphan = liveShots.with { shots -> LiveShot? in
            guard let shot = shots[id], shot.still == nil else { return nil }
            shots[id] = nil
            return shot
        }
        if let movie = orphan?.movie?.url {
            try? FileManager.default.removeItem(at: movie)
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
            applyDolly()
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
        faceTracker.reset()
        applyInitialZoom(on: next)
        status.facing = facing
        parameters.with { $0.orientation = Self.orientation(for: facing) }
        session.commitConfiguration()
        applyCaptureExtras()
        applyLogVideo()
        applyProRAW()
        applyDolly()
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
