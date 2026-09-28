import AVFoundation
import CoreImage
import UIKit

enum DualStartOutcome: Equatable {
    case running
    case waitingForAuthorization
    case unavailable(String)
}

final class DualSessionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    static var isSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    var onStatus: ((CameraStatus) -> Void)?
    var onPhoto: ((UIImage) -> Void)?
    var onFailure: ((String) -> Void)?

    private let previewView: PreviewMetalView
    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "angie.camera.dual.session")
    private let videoQueue = DispatchQueue(label: "angie.camera.dual.video")
    private let photoQueue = DispatchQueue(label: "angie.camera.dual.photo")
    private let backVideoOutput = AVCaptureVideoDataOutput()
    private let frontVideoOutput = AVCaptureVideoDataOutput()
    private let backPhotoOutput = AVCapturePhotoOutput()
    private let frontPhotoOutput = AVCapturePhotoOutput()
    private let parameters = Locked(RenderParameters())
    private let latest = Locked<[CameraFacing: CIImage]>([:])
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

    func currentThumbnailSource() -> CIImage? {
        let facing = selected.with { $0 }
        return latest.with { images in
            guard let image = images[facing] else { return nil }
            return FrameImageMaker.thumbnailSource(from: image)
        }
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
        let facing: CameraFacing = output === frontVideoOutput ? .front : .back
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = FrameImageMaker.upright(
            from: pixelBuffer,
            orientation: facing == .front ? .leftMirrored : .right,
            mirrorHorizontally: false
        )
        latest.with { $0[facing] = image }
        if image.extent.height > 1 {
            imageAspect.with { $0[facing] = image.extent.width / image.extent.height }
        }
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
        guard let data = photo.fileDataRepresentation(), let source = CIImage(data: data) else {
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
        let gradedBack = grade(back, facing: .back, parameters: capture.parameters, settings: settings)
        let gradedFront = grade(front, facing: .front, parameters: capture.parameters, settings: settings)
        let composed = DualFrameComposer.compose(back: gradedBack, front: gradedFront, settings: settings, canvas: canvas)
        let framed = framedImage(composed, parameters: capture.parameters, synchronousCaption: true)
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
        let back = images[.back].map { grade($0, facing: .back, parameters: renderParameters, settings: settings) }
        let front = images[.front].map { grade($0, facing: .front, parameters: renderParameters, settings: settings) }
        let canvas = DualFrameComposer.previewCanvas(widthOverHeight: renderParameters.aspectRatio.widthOverHeight)
        let composed = DualFrameComposer.compose(back: back, front: front, settings: settings, canvas: canvas)
        let framed = framedImage(composed, parameters: renderParameters, synchronousCaption: false)
        let token = previewToken.with { $0 }
        DispatchQueue.main.async { [weak self] in
            self?.previewView.draw(image: framed, token: token)
            self?.finishCompose()
        }
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

    private func grade(_ image: CIImage, facing: CameraFacing, parameters: RenderParameters, settings: DualSettings) -> CIImage {
        var lane = parameters
        lane.lookID = settings.lookID(for: facing)
        lane.adjustment = settings.adjustment(for: facing)
        return FrameImageMaker.graded(image, parameters: lane)
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
            if added, session.hardwareCost <= 1, session.systemPressureCost <= 1 {
                backDevice = pair.back
                frontDevice = pair.front
                applyInitialZoom(on: pair.back)
                applyInitialZoom(on: pair.front)
                isConfigured = true
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
        guard let format = Self.format(for: device, maxWidth: maxWidth) else { return false }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return false }
        session.addInputWithNoConnections(input)

        guard session.canAddOutput(video) else { return false }
        session.addOutputWithNoConnections(video)
        guard let videoPort = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first else {
            return false
        }
        let videoConnection = AVCaptureConnection(inputPorts: [videoPort], output: video)
        guard session.canAddConnection(videoConnection) else { return false }
        session.addConnection(videoConnection)

        guard session.canAddOutput(photo) else { return false }
        session.addOutputWithNoConnections(photo)
        guard let photoPort = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first else {
            return false
        }
        let photoConnection = AVCaptureConnection(inputPorts: [photoPort], output: photo)
        guard session.canAddConnection(photoConnection) else { return false }
        session.addConnection(photoConnection)
        photo.maxPhotoQualityPrioritization = .quality
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
            status.displayZoom = ZoomLadderBuilder.displayZoom(for: device.videoZoomFactor, on: device)
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

    private static func stops(for device: AVCaptureDevice) -> [ZoomStop] {
        if device.position == .front {
            return [ZoomStop(factor: ZoomLadderBuilder.clamped(1, on: device), display: 1)]
        }
        let wide = ZoomLadderBuilder.wideAngleFactor(for: device)
        let one = ZoomLadderBuilder.clamped(wide, on: device)
        var stops = [ZoomStop(factor: one, display: 1)]
        let two = ZoomLadderBuilder.clamped(wide * 2, on: device)
        if two > one + 0.05 {
            stops.append(ZoomStop(factor: two, display: ZoomLadderBuilder.displayZoom(for: two, on: device)))
        }
        return stops
    }

    private static func devicePair() -> (back: AVCaptureDevice, front: AVCaptureDevice)? {
        let backDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )
        let frontDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        )
        guard let back = backDiscovery.devices.first, let front = frontDiscovery.devices.first else { return nil }
        let supported = backDiscovery.supportedMultiCamDeviceSets.contains { set in
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
        return matches.max { lhs, rhs in
            let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            if left.width != right.width { return left.width < right.width }
            return left.height < right.height
        }
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
