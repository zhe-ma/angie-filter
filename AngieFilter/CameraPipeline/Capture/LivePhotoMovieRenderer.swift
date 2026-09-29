import AVFoundation
import CoreImage

/// Re-encodes the camera's Live Photo movie through the same geometry, color, and frame as the still.
/// Photos pairs the movie with the still by two tags: the asset's content identifier and one
/// still-image-time sample that marks the frame the still was taken from.
enum LivePhotoMovieRenderer {
    enum Failure: Error {
        case noVideoTrack
        case emptyFrame
        case readerFailed
        case writerFailed
    }

    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any
    ])
    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    /// `process` receives each frame upright and unmirrored, like the still before the pipeline, and runs off the main thread.
    static func render(
        source: URL,
        destination: URL,
        identifier: String,
        stillTime: CMTime,
        process: @escaping @Sendable (CIImage) -> CIImage
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let (transform, naturalSize, frameRate) = try await video.load(.preferredTransform, .naturalSize, .nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let audioFormat = try await audio?.load(.formatDescriptions).first

        let upright = uprightTransform(transform)
        let sourceRect = CGRect(origin: .zero, size: naturalSize).applying(upright).standardized
        let probe = process(CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: sourceRect.size)))
        let width = Int(probe.extent.width) & ~1
        let height = Int(probe.extent.height) & ~1
        guard width >= 2, height >= 2 else { throw Failure.emptyFrame }

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audio {
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.metadata = [contentIdentifier(identifier)]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(6_000_000, width * height * 4),
                AVVideoExpectedSourceFrameRateKey: max(Int(frameRate.rounded()), 1)
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let stillInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: stillTimeFormat())
        let stillAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: stillInput)
        writer.add(stillInput)

        guard reader.startReading() else { throw Failure.readerFailed }
        guard writer.startWriting() else { throw Failure.writerFailed }
        writer.startSession(atSourceTime: .zero)
        stillAdaptor.append(AVTimedMetadataGroup(
            items: [stillImageTime()],
            timeRange: CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: 100))
        ))
        stillInput.markAsFinished()

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let group = DispatchGroup()
        pump(videoInput, on: DispatchQueue(label: "angie.live.video", qos: .userInitiated), group: group) {
            guard let sample = videoOutput.copyNextSampleBuffer() else { return false }
            guard let buffer = CMSampleBufferGetImageBuffer(sample), let pool = pixels.pixelBufferPool else { return true }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let frame = shiftedToOrigin(CIImage(cvPixelBuffer: buffer).transformed(by: upright))
            let finished = shiftedToOrigin(process(frame)).cropped(to: bounds)
            var target: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target)
            guard let target else { return true }
            context.render(finished, to: target, bounds: bounds, colorSpace: colorSpace)
            pixels.append(target, withPresentationTime: time)
            return true
        }
        if let audioInput, let audioOutput {
            pump(audioInput, on: DispatchQueue(label: "angie.live.audio", qos: .userInitiated), group: group) {
                guard let sample = audioOutput.copyNextSampleBuffer() else { return false }
                audioInput.append(sample)
                return true
            }
        }

        let finished: Bool = await withCheckedContinuation { continuation in
            group.notify(queue: .global(qos: .userInitiated)) {
                if reader.status == .failed {
                    writer.cancelWriting()
                    continuation.resume(returning: false)
                    return
                }
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed)
                }
            }
        }
        guard finished else {
            try? FileManager.default.removeItem(at: destination)
            throw reader.status == .failed ? Failure.readerFailed : Failure.writerFailed
        }
    }

    /// Feeds one input until `next` reports the source is empty. `next` returns false at the end.
    private static func pump(_ input: AVAssetWriterInput, on queue: DispatchQueue, group: DispatchGroup, next: @escaping () -> Bool) {
        group.enter()
        var done = false
        input.requestMediaDataWhenReady(on: queue) {
            while !done, input.isReadyForMoreMediaData {
                if !next() {
                    done = true
                    input.markAsFinished()
                    group.leave()
                }
            }
        }
    }

    /// `preferredTransform` is written for a y-down raster; Core Image is y-up, so it is conjugated by a flip.
    private static func uprightTransform(_ transform: CGAffineTransform) -> CGAffineTransform {
        let flip = CGAffineTransform(scaleX: 1, y: -1)
        var linear = transform
        linear.tx = 0
        linear.ty = 0
        return flip.concatenating(linear).concatenating(flip)
    }

    private static func shiftedToOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        guard origin != .zero else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    private static func contentIdentifier(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.value = identifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private static let stillTimeKey = "com.apple.quicktime.still-image-time"

    private static func stillImageTime() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = stillTimeKey as NSString
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    private static func stillTimeFormat() -> CMFormatDescription? {
        let spec: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/\(stillTimeKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8 as String
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &description
        )
        return description
    }
}
