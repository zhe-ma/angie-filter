import AVFoundation
import CoreImage
import Metal

/// Writes the graded, framed picture as it is drawn: HEVC in Display P3, AAC sound, timestamps from the capture clock.
/// The writer is built on the first frame, because the framed size is only known once a frame is composed.
/// Frames that arrive while the encoder is busy are dropped instead of queued.
final class VideoRecorder: @unchecked Sendable {
    private let url: URL
    private let audioSettings: [String: Any]?
    private let frameRate: Int
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixels: AVAssetWriterInputPixelBufferAdaptor?
    private var bounds = CGRect.zero
    private var startTime = CMTime.positiveInfinity
    private var lastVideoTime = CMTime.negativeInfinity
    private var finishing = false
    private var failed = false

    private static let context: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
        ]
        guard let device = MTLCreateSystemDefaultDevice() else { return CIContext(options: options) }
        return CIContext(mtlDevice: device, options: options)
    }()
    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    init(url: URL, audioSettings: [String: Any]?, frameRate: Int) {
        self.url = url
        self.audioSettings = audioSettings
        self.frameRate = frameRate
    }

    /// Called on the video queue. The image's size on the first call fixes the movie's size.
    func appendVideo(_ image: CIImage, at time: CMTime) {
        lock.lock()
        guard !finishing, !failed, time > lastVideoTime else {
            lock.unlock()
            return
        }
        if writer == nil, !makeWriter(size: image.extent.size, start: time) {
            failed = true
            lock.unlock()
            return
        }
        guard let input = videoInput, let pixels, input.isReadyForMoreMediaData, let pool = pixels.pixelBufferPool else {
            lock.unlock()
            return
        }
        let bounds = self.bounds
        lastVideoTime = time
        lock.unlock()

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let origin = image.extent.origin
        let placed = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        Self.context.render(placed, to: buffer, bounds: bounds, colorSpace: Self.colorSpace)

        lock.lock()
        defer { lock.unlock() }
        guard !finishing, input.isReadyForMoreMediaData else { return }
        pixels.append(buffer, withPresentationTime: time)
    }

    /// Called on the audio queue. Sound before the first frame is dropped so the movie starts on a picture.
    func appendAudio(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finishing, let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= startTime else { return }
        audioInput.append(sample)
    }

    /// Nil when nothing was written or the writer failed; the partial file is removed.
    func finish(_ completion: @escaping @Sendable (URL?) -> Void) {
        lock.lock()
        finishing = true
        let writer = self.writer
        let inputs = [videoInput, audioInput].compactMap { $0 }
        lock.unlock()
        let url = self.url
        guard let writer, writer.status == .writing else {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(nil)
            return
        }
        inputs.forEach { $0.markAsFinished() }
        writer.finishWriting {
            let ok = writer.status == .completed
            if !ok {
                PerfLog.line("recording failed: \(writer.error.map { "\($0)" } ?? "unknown")")
                try? FileManager.default.removeItem(at: url)
            }
            completion(ok ? url : nil)
        }
    }

    private func makeWriter(size: CGSize, start: CMTime) -> Bool {
        let width = Int(size.width) & ~1
        let height = Int(size.height) & ~1
        guard width >= 2, height >= 2 else { return false }
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(8_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: frameRate
            ]
        ])
        video.expectsMediaDataInRealTime = true
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        guard writer.canAdd(video) else { return false }
        writer.add(video)
        if let audioSettings, writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }
        guard writer.startWriting() else {
            PerfLog.line("recording could not start: \(writer.error.map { "\($0)" } ?? "unknown")")
            return false
        }
        writer.startSession(atSourceTime: start)
        self.writer = writer
        videoInput = video
        self.pixels = pixels
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        startTime = start
        PerfLog.line("recording \(width)x\(height) at \(frameRate)fps, sound \(audioInput != nil ? "yes" : "no")")
        return true
    }
}
