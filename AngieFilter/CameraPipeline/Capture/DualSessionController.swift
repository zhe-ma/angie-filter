import AVFoundation
import CoreImage
import UIKit

enum DualStartOutcome: Equatable {
    case running
    case waitingForAuthorization
    case unavailable(String)
}

final class DualSessionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    static var isSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    var onStatus: ((CameraStatus) -> Void)?
    var onPhoto: ((UIImage) -> Void)?
    var onFailure: ((String) -> Void)?

    private let previewView: PreviewMetalView
    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "angie.camera.dual.session")
    private let videoQueue = DispatchQueue(label: "angie.camera.dual.video", qos: .userInteractive)
    private let photoQueue = DispatchQueue(label: "angie.camera.dual.photo")
    private let backVideoOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let backPhotoOutput = AVCapturePhotoOutput()
    private let frontPhotoOutput = AVCapturePhotoOutput()
    private let parameters = Locked(RenderParameters())
    private let latest = Locked<[CameraFacing: CIImage]>([:])
    private let thumbnailTaps: [CameraFacing: ThumbnailFrameTap] = [.back: ThumbnailFrameTap(), .front: ThumbnailFrameTap()]
    private let faceTrackers: [CameraFacing: FaceTracker] = [.back: FaceTracker(), .front: FaceTracker()]
    private let imageAspect = Locked<[CameraFacing: CGFloat]>([:])
    private let selected = Locked(CameraFacing.back)
    private let flashMode = Locked(FlashMode.off)
    private let composeState = Locked((busy: false, again: false))
    private let pending = Locked<PendingCapture?>(nil)
    private let captureGeneration = Locked(0)
    private let shotLanes = Locked<[Int64: ShotLane]>([:])
    private let previewToken = Locked(0)
    private let captions = FrameCaptionCache()
    private let modelName = PhoneModelName.marketingName(for: DeviceMachine.identifier)
    private var backDevice: AVCaptureDevice?
    private var frontDevice: AVCaptureDevice?
    private var status = CameraStatus()
    private var isConfigured = false
    /// Touched only on `sessionQueue`.
    private var startID = 0
    private var wantsRunning = false
    private var activeStart: (id: Int, completion: (DualStartOutcome) -> Void)?
    private var videoMode = false
    private var frameRate = VideoFrameRate.thirty
    private var audioInput: AVCaptureDeviceInput?
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "angie.camera.dual.audio")
    private let recorder = Locked<VideoRecorder?>(nil)
    private let recordingHold = Locked(HoldOrientation.portrait)
    /// The composite is recorded on the back camera's clock, one frame per back frame.
    private let backFrameTime = Locked(CMTime.negativeInfinity)
    private let recordedTime = Locked(CMTime.negativeInfinity)

    init(previewView: PreviewMetalView) {
        self.previewView = previewView
        super.init()
        for output in [backVideoOutput, frontVideoOutput] {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionRuntimeError),
            name: .AVCaptureSessionRuntimeError,
            object: session
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func updateRenderParameters(_ body: (inout RenderParameters) -> Void) {
        parameters.with { value in
            body(&value)
            value.frameModelName = modelName
        }
    }

    func requestThumbnailSource(_ completion: @escaping @Sendable (CIImage?) -> Void) {
        thumbnailTaps[selected.with { $0 }]?.request(completion)
    }

    func start(completion: @escaping (DualStartOutcome) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(.unavailable("这台设备不能同时打开前后镜头"))
                }
                return
            }
            self.startID += 1
            let id = self.startID
            self.wantsRunning = true
            let outcome = self.beginStart(startID: id)
            if case .waitingForAuthorization = outcome {
                self.activeStart = (id, completion)
            }
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else {
                if let completion {
                    DispatchQueue.main.async(execute: completion)
                }
                return
            }
            self.startID += 1
            self.wantsRunning = false
            self.activeStart = nil
            if self.session.isRunning {
                self.session.stopRunning()
                self.status.isRunning = false
                self.publishStatus()
            }
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    func setSelected(_ facing: CameraFacing) {
        selected.with { $0 = facing }
        sessionQueue.async { [weak self] in
            self?.publishStatus()
        }
    }

    func setZoom(factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let facing = self.selected.with { $0 }
            guard let device = facing == .back ? self.backDevice : self.frontDevice else { return }
            let clamped = ZoomLadderBuilder.clamped(factor, on: device)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                self.publishStatus()
            } catch {
                self.publishFailure("变焦失败")
            }
        }
    }

    func focus(atCellPoint point: CGPoint, facing: CameraFacing, cellAspect: CGFloat) {
        let aspect = imageAspect.with { $0[facing] } ?? cellAspect
        let devicePoint = DualFocusMap.devicePoint(
            cellPoint: point,
            cellAspect: cellAspect,
            imageAspect: aspect,
            facing: facing
        )
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let device = facing == .back ? self.backDevice : self.frontDevice
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                self.publishFailure("对焦失败")
            }
        }
    }

    func setVideoMode(_ on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoMode = on
            self.applyFrameRate()
            guard on, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
                self.applyAudio()
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                self?.sessionQueue.async { self?.applyAudio() }
            }
        }
    }

    func startRecording(to url: URL) {
        let hold = parameters.with { $0.hold }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let sound = self.audioInput != nil
                ? self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)
                : nil
            self.recordingHold.with { $0 = hold }
            self.recordedTime.with { $0 = .negativeInfinity }
            let fps = self.backDevice.map { Int((1 / max($0.activeVideoMinFrameDuration.seconds, 0.001)).rounded()) } ?? 30
            self.recorder.with { $0 = VideoRecorder(url: url, audioSettings: sound, frameRate: fps) }
        }
    }

    func setVideoFrameRate(_ rate: VideoFrameRate) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.frameRate = rate
            self.applyFrameRate()
        }
    }

    private func applyFrameRate() {
        for device in [backDevice, frontDevice].compactMap({ $0 }) {
            guard (try? device.lockForConfiguration()) != nil else { continue }
            setFrameDurations(on: device)
            device.unlockForConfiguration()
        }
    }

    /// Needs the device locked. 24fps is pinned in video mode; otherwise up to 30, free to slow to 15 in low light.
    private func setFrameDurations(on device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        if videoMode, frameRate == .twentyFour, ranges.contains(where: { $0.minFrameRate <= 24 && $0.maxFrameRate >= 24 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 24)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 24)
            return
        }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
        let slowest = ranges.map(\.minFrameRate).min() ?? 30
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(max(15, slowest.rounded(.up))))
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
        flashMode.with { $0 = mode }
        sessionQueue.async { [weak self] in
            self?.status.flashMode = mode
            self?.publishStatus()
        }
    }

    func capturePhoto() {
        let inFlight = pending.with { $0 != nil }
        guard !inFlight else { return }
        let day = FrameDateText.string(from: Date())
        let place = parameters.with { $0.framePlace }
        let generation = captureGeneration.with { value -> Int in
            value += 1
            return value
        }
        var frozen = parameters.with { $0 }
        frozen.quality = .still
        frozen.frameDate = day
        frozen.framePlace = place
        pending.with { $0 = PendingCapture(generation: generation, parameters: frozen) }
        photoQueue.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.expireCapture(generation)
        }
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else {
                self?.expireCapture(generation)
                return
            }
            let flash = self.avFlashMode(self.flashMode.with { $0 })
            self.capture(self.backPhotoOutput, flash: flash, generation: generation, facing: .back)
            self.capture(self.frontPhotoOutput, flash: .off, generation: generation, facing: .front)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder.with { $0 }?.appendAudio(sampleBuffer)
            return
        }
        let facing: CameraFacing = output === frontVideoOutput ? .front : .back
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if facing == .back {
            backFrameTime.with { $0 = CMSampleBufferGetPresentationTimeStamp(sampleBuffer) }
        }
        let image = FrameImageMaker.upright(
            from: pixelBuffer,
            orientation: facing == .front ? .leftMirrored : .right,
            mirrorHorizontally: false
        )
        if image.extent.height > 1 {
            imageAspect.with { $0[facing] = image.extent.width / image.extent.height }
        }
        let preview = FrameImageMaker.scaledForPreview(image)
        latest.with { $0[facing] = preview }
        thumbnailTaps[facing]?.offer(preview)
        scheduleCompose()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard output === backPhotoOutput || output === frontPhotoOutput else { return }
        let request = shotLanes.with { lanes in
            lanes.removeValue(forKey: photo.resolvedSettings.uniqueID)
        }
        guard let request else { return }
        if error != nil {
            resolvePhoto(generation: request.generation, facing: request.facing, image: nil)
            return
        }
        guard let data = photo.fileDataRepresentation(), let source = PhotoOrientation.uprightImage(from: data) else {
            resolvePhoto(generation: request.generation, facing: request.facing, image: nil)
            return
        }
        let upright = FrameImageMaker.upright(from: source, orientation: .up, mirrorHorizontally: request.facing == .front)
        resolvePhoto(generation: request.generation, facing: request.facing, image: upright)
    }

    private func expireCapture(_ generation: Int) {
        let expired = pending.with { pending -> Bool in
            guard pending?.generation == generation else { return false }
            pending = nil
            return true
        }
        forgetLanes(generation: generation)
        if expired {
            publishFailure("没有拿到两路照片")
        }
    }

    private func forgetLanes(generation: Int) {
        shotLanes.with { lanes in
            lanes = lanes.filter { $0.value.generation != generation }
        }
    }

    private func resolvePhoto(generation: Int, facing: CameraFacing, image: CIImage?) {
        let event = pending.with { pending -> PhotoEvent in
            guard var current = pending, current.generation == generation else { return .ignored }
            guard let image else {
                pending = nil
                return .failed
            }
            if facing == .front {
                current.front = image
            } else {
                current.back = image
            }
            if current.back != nil, current.front != nil {
                pending = nil
                return .ready(current)
            }
            pending = current
            return .waiting
        }
        switch event {
        case .ignored, .waiting:
            break
        case .failed:
            forgetLanes(generation: generation)
            publishFailure("没有拿到两路照片")
        case .ready(let capture):
            photoQueue.async { [weak self] in
                self?.finishPhoto(capture)
            }
        }
    }

    private func finishPhoto(_ capture: PendingCapture) {
        guard let back = capture.back, let front = capture.front, let settings = capture.parameters.dual else {
            publishFailure("没有拿到两路照片")
            return
        }
        let canvas = DualFrameComposer.stillCanvas(
            widthOverHeight: capture.parameters.aspectRatio.widthOverHeight,
            back: back,
            front: front
        )
        let beauty = capture.parameters.beauty > 0
        let gradedBack = grade(back, facing: .back, parameters: capture.parameters, settings: settings,
                               faces: beauty ? FaceTracker.detect(in: back) : [])
        let gradedFront = grade(front, facing: .front, parameters: capture.parameters, settings: settings,
                                faces: beauty ? FaceTracker.detect(in: front) : [])
        let composed = DualFrameComposer.compose(back: gradedBack, front: gradedFront, settings: settings, canvas: canvas)
        let turned = FrameImageMaker.turned(composed, hold: capture.parameters.hold)
        let framed = framedImage(turned, parameters: capture.parameters, synchronousCaption: true)
        guard let image = makeStill(framed) else {
            publishFailure("照片处理失败")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onPhoto?(image)
        }
    }

    private func scheduleCompose() {
        let start = composeState.with { state -> Bool in
            if state.busy {
                state.again = true
                return false
            }
            state.busy = true
            state.again = false
            return true
        }
        if start {
            videoQueue.async { [weak self] in
                self?.composePreview()
            }
        }
    }

    private func composePreview() {
        let renderParameters = parameters.with { $0 }
        guard let settings = renderParameters.dual else {
            finishCompose()
            return
        }
        let images = latest.with { $0 }
        let back = images[.back].map {
            grade($0, facing: .back, parameters: renderParameters, settings: settings, faces: previewFaces($0, facing: .back, parameters: renderParameters))
        }
        let front = images[.front].map {
            grade($0, facing: .front, parameters: renderParameters, settings: settings, faces: previewFaces($0, facing: .front, parameters: renderParameters))
        }
        let canvas = DualFrameComposer.previewCanvas(widthOverHeight: renderParameters.aspectRatio.widthOverHeight)
        let composed = DualFrameComposer.compose(back: back, front: front, settings: settings, canvas: canvas)
        let framed = framedImage(composed, parameters: renderParameters, synchronousCaption: false)
        let token = previewToken.with { $0 }
        previewView.draw(image: framed, token: token)
        record(composed: composed, framed: framed, parameters: renderParameters)
        finishCompose()
    }

    /// At most one recorded frame per back-camera frame, however often the composite is redrawn.
    private func record(composed: CIImage, framed: CIImage, parameters: RenderParameters) {
        guard let active = recorder.with({ $0 }) else { return }
        let time = backFrameTime.with { $0 }
        let fresh = recordedTime.with { last -> Bool in
            guard time > last else { return false }
            last = time
            return true
        }
        guard fresh else { return }
        let hold = recordingHold.with { $0 }
        let recorded = hold == .portrait
            ? framed
            : framedImage(FrameImageMaker.turned(composed, hold: hold), parameters: parameters, synchronousCaption: true)
        active.appendVideo(recorded, at: time)
    }

    private func applyAudio() {
        guard isConfigured else { return }
        let wants = videoMode && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        guard wants != (audioInput != nil) else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard wants else {
            for connection in session.connections where connection.output === audioOutput {
                session.removeConnection(connection)
            }
            if let audioInput { session.removeInput(audioInput) }
            session.removeOutput(audioOutput)
            audioInput = nil
            return
        }
        guard let microphone = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(input) else { return }
        session.addInputWithNoConnections(input)
        guard session.canAddOutput(audioOutput) else {
            session.removeInput(input)
            return
        }
        session.addOutputWithNoConnections(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        let port = input.ports(for: .audio, sourceDeviceType: microphone.deviceType, sourceDevicePosition: .back).first
            ?? input.ports.first { $0.mediaType == .audio }
        guard let port else {
            session.removeOutput(audioOutput)
            session.removeInput(input)
            return
        }
        let connection = AVCaptureConnection(inputPorts: [port], output: audioOutput)
        guard session.canAddConnection(connection) else {
            session.removeOutput(audioOutput)
            session.removeInput(input)
            return
        }
        session.addConnection(connection)
        audioInput = input
    }

    private func finishCompose() {
        let again = composeState.with { state -> Bool in
            let again = state.again
            state.again = false
            state.busy = again
            return again
        }
        if again {
            videoQueue.async { [weak self] in
                self?.composePreview()
            }
        }
    }

    private func grade(_ image: CIImage, facing: CameraFacing, parameters: RenderParameters, settings: DualSettings, faces: [FaceRegion]) -> CIImage {
        var lane = parameters
        lane.lookID = settings.lookID(for: facing)
        lane.adjustment = settings.adjustment(for: facing)
        return FrameImageMaker.graded(image, faces: faces, parameters: lane)
    }

    private func previewFaces(_ image: CIImage, facing: CameraFacing, parameters: RenderParameters) -> [FaceRegion] {
        guard parameters.beauty > 0 else { return [] }
        return faceTrackers[facing]?.faces(offering: image) ?? []
    }

    private func beginStart(startID: Int) -> DualStartOutcome {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status.authorization = .authorized
            return openSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                self?.sessionQueue.async {
                    self?.finishAuthorization(allowed: allowed, startID: startID)
                }
            }
            return .waitingForAuthorization
        default:
            status.authorization = .denied
            publishStatus()
            return .unavailable("需要相机权限才能同时打开前后镜头")
        }
    }

    private func finishAuthorization(allowed: Bool, startID: Int) {
        guard wantsRunning, self.startID == startID else { return }
        let outcome: DualStartOutcome
        if allowed {
            status.authorization = .authorized
            outcome = openSession()
        } else {
            status.authorization = .denied
            publishStatus()
            outcome = .unavailable("需要相机权限才能同时打开前后镜头")
        }
        let completion = activeStart?.id == startID ? activeStart?.completion : nil
        activeStart = nil
        if let completion {
            DispatchQueue.main.async {
                completion(outcome)
            }
        }
    }

    /// Writes a multicam format every time. Another session may have changed the devices since the last start.
    private func openSession() -> DualStartOutcome {
        guard wantsRunning else {
            return .unavailable("这台设备不能同时打开前后镜头")
        }
        guard Self.isSupported else {
            publishFailure("这台设备不能同时打开前后镜头")
            return .unavailable("这台设备不能同时打开前后镜头")
        }
        guard configure() else {
            return .unavailable("这台设备不能同时打开前后镜头")
        }
        previewToken.with { $0 = previewView.claimDrawer() }
        if !session.isRunning {
            session.startRunning()
        }
        PerfLog.line("dual: configured, running \(session.isRunning)")
        status.isRunning = session.isRunning
        status.hasCamera = true
        publishStatus()
        if session.isRunning {
            return .running
        }
        publishFailure("这台设备不能同时打开前后镜头")
        return .unavailable("这台设备不能同时打开前后镜头")
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        sessionQueue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            if error?.code == .mediaServicesWereReset {
                _ = self.openSession()
                return
            }
            self.publishFailure("双摄中断了")
        }
    }

    private func configure() -> Bool {
        isConfigured = false
        guard let pair = Self.devicePair() else {
            PerfLog.line("dual: no multicam back/front pair, supported \(Self.isSupported)")
            status.hasCamera = false
            publishFailure("这台设备不能同时打开前后镜头")
            publishStatus()
            return false
        }
        let widths: [Int32] = [1920, 1280, 960]
        for width in widths {
            session.beginConfiguration()
            removeAll()
            let added = add(pair.back, video: backVideoOutput, photo: backPhotoOutput, maxWidth: width)
                && add(pair.front, video: frontVideoOutput, photo: frontPhotoOutput, maxWidth: width)
            session.commitConfiguration()
            PerfLog.line(String(
                format: "dual: width %d added %@ hardwareCost %.2f pressureCost %.2f",
                width, added ? "yes" : "no", session.hardwareCost, session.systemPressureCost
            ))
            if added, session.hardwareCost <= 1, session.systemPressureCost <= 1 {
                PerfLog.line("dual: back format \(CaptureFormatLog.describe(pair.back.activeFormat, on: pair.back))")
                PerfLog.line("dual: front format \(CaptureFormatLog.describe(pair.front.activeFormat, on: pair.front))")
                backDevice = pair.back
                frontDevice = pair.front
                applyInitialZoom(on: pair.back)
                applyInitialZoom(on: pair.front)
                isConfigured = true
                applyAudio()
                return true
            }
        }
        session.beginConfiguration()
        removeAll()
        session.commitConfiguration()
        status.hasCamera = false
        publishFailure("这台设备不能同时打开前后镜头")
        publishStatus()
        return false
    }

    private func add(_ device: AVCaptureDevice, video: AVCaptureVideoDataOutput, photo: AVCapturePhotoOutput, maxWidth: Int32) -> Bool {
        func fail(_ step: String) -> Bool {
            PerfLog.line("dual: \(device.position == .front ? "front" : "back") failed at \(step), max width \(maxWidth)")
            return false
        }
        guard let format = Self.format(for: device, maxWidth: maxWidth) else { return fail("format") }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            // Match the single-camera photo preset: 8-bit Display P3, up to 30fps, free to slow to 15 in low light,
            // and no video HDR. Left automatic, a 10-bit format switches to HLG and the frames look overexposed.
            device.activeColorSpace = format.supportedColorSpaces.contains(.P3_D65) ? .P3_D65 : .sRGB
            setFrameDurations(on: device)
            if format.isVideoHDRSupported {
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = false
            }
            device.unlockForConfiguration()
        } catch {
            return fail("lock")
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return fail("input") }
        session.addInputWithNoConnections(input)

        guard session.canAddOutput(video) else { return fail("video output") }
        session.addOutputWithNoConnections(video)
        guard let videoPort = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first else {
            return fail("video port")
        }
        let videoConnection = AVCaptureConnection(inputPorts: [videoPort], output: video)
        guard session.canAddConnection(videoConnection) else { return fail("video connection") }
        session.addConnection(videoConnection)

        guard session.canAddOutput(photo) else { return fail("photo output") }
        session.addOutputWithNoConnections(photo)
        guard let photoPort = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first else {
            return fail("photo port")
        }
        let photoConnection = AVCaptureConnection(inputPorts: [photoPort], output: photo)
        guard session.canAddConnection(photoConnection) else { return fail("photo connection") }
        session.addConnection(photoConnection)
        PhotoOrientation.preparePortrait(photoConnection)
        photo.maxPhotoQualityPrioritization = .quality
        if let largest = format.supportedMaxPhotoDimensions.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photo.maxPhotoDimensions = largest
        }
        return true
    }

    private func removeAll() {
        for connection in Array(session.connections) {
            session.removeConnection(connection)
        }
        for input in Array(session.inputs) {
            session.removeInput(input)
        }
        for output in Array(session.outputs) {
            session.removeOutput(output)
        }
        audioInput = nil
    }

    private func applyInitialZoom(on device: AVCaptureDevice) {
        let factor = ZoomLadderBuilder.clamped(ZoomLadderBuilder.wideAngleFactor(for: device), on: device)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }
    }

    private func capture(
        _ output: AVCapturePhotoOutput,
        flash: AVCaptureDevice.FlashMode,
        generation: Int,
        facing: CameraFacing
    ) {
        let settings = AVCapturePhotoSettings()
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        shotLanes.with { $0[settings.uniqueID] = ShotLane(generation: generation, facing: facing) }
        if output.supportedFlashModes.contains(flash) {
            settings.flashMode = flash
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    private func publishStatus() {
        let facing = selected.with { $0 }
        let device = facing == .back ? backDevice : frontDevice
        status.facing = facing
        status.flashMode = flashMode.with { $0 }
        status.authorization = status.authorization == .unknown ? .authorized : status.authorization
        if let device {
            status.zoomStops = Self.stops(for: device)
            status.zoomFactor = device.videoZoomFactor
            status.focalLength = ZoomLadderBuilder.focalLength(for: device.videoZoomFactor, on: device)
        }
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

    private func avFlashMode(_ mode: FlashMode) -> AVCaptureDevice.FlashMode {
        switch mode {
        case .off: return .off
        case .on: return .on
        case .auto: return .auto
        }
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

    private func makeStill(_ image: CIImage) -> UIImage? {
        let extent = image.extent.integral
        guard extent.width > 1, extent.height > 1 else { return nil }
        let context = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
        ])
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Multicam formats are smaller, so digital presets stop at 50mm.
    private static func stops(for device: AVCaptureDevice) -> [ZoomStop] {
        ZoomLadderBuilder.stops(for: device, longestPreset: 50)
    }

    /// One discovery session over both sides. A session limited to one position only reports
    /// multicam sets made of that side's cameras, so it never shows a back and front pair.
    private static func devicePair() -> (back: AVCaptureDevice, front: AVCaptureDevice)? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard let back = discovery.devices.first(where: { $0.position == .back }),
              let front = discovery.devices.first(where: { $0.position == .front }) else { return nil }
        let supported = discovery.supportedMultiCamDeviceSets.contains { set in
            set.contains(back) && set.contains(front)
        }
        guard supported else { return nil }
        return (back, front)
    }

    private static func format(for device: AVCaptureDevice, maxWidth: Int32) -> AVCaptureDevice.Format? {
        let matches = device.formats.filter { format in
            guard format.isMultiCamSupported else { return false }
            let supports30 = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
            guard supports30 else { return false }
            let width = CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
            return width <= maxWidth && width >= 640
        }
        return matches.max { rank($0) < rank($1) }
    }

    /// Closest to the single-camera preview first: 8-bit like the photo formats, the sensor's own 4:3
    /// so a 3:4 crop loses nothing, a full readout over a binned one, full range, then the largest.
    private static func rank(_ format: AVCaptureDevice.Format) -> (Int, Int, Int, Int, Int32, Int32) {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let fullRange = subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? 1 : 0
        let eightBit = fullRange == 1 || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0
        let ratio = Double(size.width) / Double(max(size.height, 1))
        let fourThree = abs(ratio - 4.0 / 3.0) < 0.01 ? 1 : 0
        let fullReadout = format.isVideoBinned ? 0 : 1
        return (eightBit, fourThree, fullReadout, fullRange, size.width, size.height)
    }
}

private struct ShotLane {
    var generation: Int
    var facing: CameraFacing
}

private struct PendingCapture {
    var generation: Int
    var back: CIImage?
    var front: CIImage?
    var parameters: RenderParameters
}

private enum PhotoEvent {
    case ignored
    case waiting
    case failed
    case ready(PendingCapture)
}
