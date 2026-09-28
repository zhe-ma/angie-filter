import AVFoundation
import CoreImage
import Metal
import UIKit

final class CameraSessionController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    let previewView: PreviewMetalView

    var onStatus: ((CameraStatus) -> Void)?
    var onPhoto: ((UIImage) -> Void)?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "angie.camera.session")
    private let videoQueue = DispatchQueue(label: "angie.camera.video")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let parameters = Locked(RenderParameters())
    private let latestSource = Locked<CIImage?>(nil)
    private let captureFacing = Locked(CameraFacing.back)
    private var status = CameraStatus()
    private var device: AVCaptureDevice?
    private var isConfigured = false
    private let renderBusy = Locked(false)
    private let captions = FrameCaptionCache()
    private let modelName = PhoneModelName.marketingName(for: DeviceMachine.identifier)
    private let shutterDate = Locked("")
    private let shutterPlace = Locked("")

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

    func currentThumbnailSource() -> CIImage? {
        latestSource.with { image in
            guard let image else { return nil }
            return FrameImageMaker.thumbnailSource(from: image)
        }
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
                self.status.displayZoom = ZoomLadderBuilder.displayZoom(for: clamped, on: device)
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
        shutterDate.with { $0 = day }
        shutterPlace.with { $0 = place }
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured else { return }
            let settings = AVCapturePhotoSettings()
            let flash = self.avFlashMode(self.status.flashMode)
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            self.captureFacing.with { $0 = self.status.facing }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let busy = renderBusy.with { flag -> Bool in
            if flag { return true }
            flag = true
            return false
        }
        guard !busy else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            renderBusy.with { $0 = false }
            return
        }
        let renderParameters = parameters.with { $0 }
        let source = FrameImageMaker.sourceImage(from: pixelBuffer, parameters: renderParameters)
        latestSource.with { $0 = source }
        let graded = FrameImageMaker.graded(source, parameters: renderParameters)
        let framed = framedImage(graded, parameters: renderParameters, synchronousCaption: false)
        let busyFlag = renderBusy
        DispatchQueue.main.async { [weak self] in
            self?.previewView.draw(image: framed)
            busyFlag.with { $0 = false }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            publishFailure(error.localizedDescription)
            return
        }
        guard let data = photo.fileDataRepresentation(), let photoImage = CIImage(data: data) else {
            publishFailure("没有拿到照片")
            return
        }
        var renderParameters = parameters.with { $0 }
        renderParameters.quality = .still
        renderParameters.orientation = .up
        renderParameters.mirrorHorizontally = captureFacing.with { $0 } == .front
        renderParameters.frameDate = shutterDate.with { $0 }
        renderParameters.framePlace = shutterPlace.with { $0 }
        let source = FrameImageMaker.sourceImage(from: photoImage, parameters: renderParameters)
        let graded = FrameImageMaker.graded(source, parameters: renderParameters)
        let framed = framedImage(graded, parameters: renderParameters, synchronousCaption: true)
        guard let image = previewView.makeImage(framed) else {
            publishFailure("照片处理失败")
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onPhoto?(image)
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
        }
        if !session.isRunning {
            session.startRunning()
        }
        status.isRunning = session.isRunning
        publishStatus()
    }

    private func reconfigure(facing: CameraFacing) {
        session.beginConfiguration()
        for input in session.inputs {
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
    }

    private func applyInitialZoom(on device: AVCaptureDevice) {
        let stops = ZoomLadderBuilder.stops(for: device)
        let wide = stops.first { abs($0.display - 1) < 0.05 }?.factor ?? device.videoZoomFactor
        let factor = ZoomLadderBuilder.clamped(wide, on: device)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = factor
            device.unlockForConfiguration()
        }
        status.zoomStops = stops
        status.zoomFactor = factor
        status.displayZoom = ZoomLadderBuilder.displayZoom(for: factor, on: device)
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
