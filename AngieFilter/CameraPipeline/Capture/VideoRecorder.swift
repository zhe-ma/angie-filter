import AVFoundation
import CoreImage
import Metal

/// Writes the graded, framed picture as it is drawn: HEVC in Display P3, AAC sound, timestamps from the capture clock.
/// The writer is built on the first frame, because the framed size is only known once a frame is composed.
/// Frames that arrive while the encoder is busy are dropped instead of queued.
/// Sped up by `speedUp`, it keeps one frame in that many by time and squeezes the timestamps, for 延时, blending the
/// frames just before each kept one into it.
final class VideoRecorder: @unchecked Sendable {
    private let url: URL
    private let audioSettings: [String: Any]?
    private let frameRate: Int
    private let speedUp: Int
    /// Sped up, the capture time the next kept frame is due at.
    private var nextKept = CMTime.negativeInfinity
    /// Sped up, the frames just before the next kept one, to blend into it.
    private var held: [CIImage] = []
    /// Frames blended into each kept one, the kept one included: at 6 times, half of what it stands for, like a
    /// 180° shutter, so the walk smears a little instead of stepping.
    private static let lapseBlend = 3
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

    init(url: URL, audioSettings: [String: Any]?, frameRate: Int, speedUp: Int = 1) {
        self.url = url
        self.audioSettings = audioSettings
        self.frameRate = frameRate
        self.speedUp = max(speedUp, 1)
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
        var written = time
        var blended: [CIImage] = []
        let origin = image.extent.origin
        let placed = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        if speedUp > 1 {
            let frame = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))
            // Half a frame early still counts, so frames a little off their beat aren't skipped.
            let half = CMTimeMultiplyByRatio(frame, multiplier: 1, divisor: 2)
            guard time >= nextKept - half else {
                // The frames just before a kept one are blended into it.
                let blendFrom = nextKept - half - CMTimeMultiply(frame, multiplier: Int32(Self.lapseBlend - 1))
                let holds = nextKept.isNumeric && time >= blendFrom
                let bounds = self.bounds
                lastVideoTime = time
                lock.unlock()
                if holds {
                    hold(placed, pool: pool, bounds: bounds)
                }
                return
            }
            let step = CMTimeMultiply(frame, multiplier: Int32(speedUp))
            // On the beat, unless frames were lost; then from this one.
            nextKept = nextKept.isNumeric ? max(nextKept + step, time + step - half) : time + step
            written = startTime + CMTimeMultiplyByRatio(time - startTime, multiplier: 1, divisor: Int32(speedUp))
            blended = held
            held = []
        }
        let bounds = self.bounds
        lastVideoTime = time
        lock.unlock()

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        Self.context.render(Self.average(blended + [placed]), to: buffer, bounds: bounds, colorSpace: Self.colorSpace)

        lock.lock()
        defer { lock.unlock() }
        guard !finishing, input.isReadyForMoreMediaData else { return }
        pixels.append(buffer, withPresentationTime: written)
    }

    /// A frame to blend into the next kept one, in a buffer of its own so no camera buffer is held.
    private func hold(_ image: CIImage, pool: CVPixelBufferPool, bounds: CGRect) {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        Self.context.render(image, to: buffer, bounds: bounds, colorSpace: Self.colorSpace)
        let copy = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: Self.colorSpace])
        lock.lock()
        held.append(copy)
        lock.unlock()
    }

    /// Each image at an equal share.
    private static func average(_ images: [CIImage]) -> CIImage {
        guard images.count > 1, let first = images.first else { return images.first ?? CIImage.empty() }
        let share = 1 / CGFloat(images.count)
        func scaled(_ image: CIImage) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: share, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: share, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: share, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: share)
            ])
        }
        return images.dropFirst().reduce(scaled(first)) { sum, image in
            scaled(image).applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: sum])
        }
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
        PerfLog.line("recording \(width)x\(height) at \(frameRate)fps, sound \(audioInput != nil ? "yes" : "no"), speed x\(speedUp)")
        return true
    }
}
