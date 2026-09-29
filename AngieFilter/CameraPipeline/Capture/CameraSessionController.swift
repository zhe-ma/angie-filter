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
    /// Touched only on `sessionQueue`.
    private var liveWanted = false
    private var videoMode = false
    private var audioInput: AVCaptureDeviceInput?

    override init() {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("This device has no Metal GPU.")
        }
        previewView = PreviewMetalView(device: metalDevice)
        super.init()
    }

    func updateRenderParameters(_ body: (inout RenderParameters) -> Void) {
        parameters.with { value in
            body(&value)
            value.frameModelName = modelName
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
            } catch {
                self.publishFailure("变焦失败")
            }
        }
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
            self.applyExtrasAskingForMicrophone(on)
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
            self.recorder.with { $0 = VideoRecorder(url: url, audioSettings: sound) }
        }
    }

    func stopRecording(_ completion: @escaping (URL?) -> Void) {
        sessionQueue.async { [weak self] in
            let active = self?.recorder.with { recorder -> VideoRecorder? in
                defer { recorder = nil }
                return recorder
            }
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
            let settings = AVCapturePhotoSettings()
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
            PerfLog.line("preview look \(renderParameters.lookID), buffer \(CVPixelBufferGetWidth(pixelBuffer))x\(CVPixelBufferGetHeight(pixelBuffer))")
        }
        let source = FrameImageMaker.sourceImage(from: pixelBuffer, parameters: renderParameters)
        thumbnailTap.offer(source)
        let graded = FrameImageMaker.graded(source, parameters: renderParameters)
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
        guard let data = photo.fileDataRepresentation(), let photoImage = PhotoOrientation.uprightImage(from: data) else {
            publishFailure("没有拿到照片")
            return
        }
        var renderParameters = parameters.with { $0 }
        renderParameters.quality = .still
        renderParameters.orientation = .up
        renderParameters.mirrorHorizontally = captureFacing.with { $0 } == .front
        renderParameters.frameDate = shutterDate.with { $0 }
        renderParameters.framePlace = shutterPlace.with { $0 }
        renderParameters.hold = shutterHold.with { $0 }
        let framed = stillPipeline(photoImage, parameters: renderParameters)
        guard let image = previewView.makeImage(framed) else {
            publishFailure("照片处理失败")
            return
        }
        let id = photo.resolvedSettings.uniqueID
        let live = photo.resolvedSettings.livePhotoMovieDimensions.width > 0
            && liveShots.with { shots -> Bool in
                guard shots[id] != nil else { return false }
                shots[id]?.still = (image, renderParameters)
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
                    self?.stillPipeline(frame, parameters: parameters) ?? frame
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
    private func stillPipeline(_ image: CIImage, parameters: RenderParameters) -> CIImage {
        let source = FrameImageMaker.sourceImage(from: image, parameters: parameters)
        let graded = FrameImageMaker.graded(source, parameters: parameters)
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
        }
        if !session.isRunning {
            previewToken.with { $0 = previewView.claimDrawer() }
            session.startRunning()
        }
        status.isRunning = session.isRunning
        publishStatus()
    }

    private func reconfigure(facing: CameraFacing) {
        session.beginConfiguration()
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
        applyInitialZoom(on: next)
        status.facing = facing
        parameters.with { $0.orientation = Self.orientation(for: facing) }
        session.commitConfiguration()
        applyCaptureExtras()
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
    var still: (image: UIImage, parameters: RenderParameters)?
    var movie: (url: URL, stillTime: CMTime)?
}
