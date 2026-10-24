import AVFoundation
import CoreImage
import Photos

/// Writes film-rendered frames and microphone audio to a QuickTime movie, then files it in Photos.
final class VideoRecorder {
    let size: CGSize
    private(set) var frames = 0
    private(set) var dropped = 0
    /// The most recent frame written, for a thumbnail.
    var lastFrame: CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let context: CIContext
    private let url: URL
    private let lock = NSLock()
    private var started = false
    private var finishing = false
    private var startTime = CMTime.invalid
    private var latest: CVPixelBuffer?

    /// Frames are graded for Rec. 709, which is how players and Photos read the file.
    static let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    init?(size: CGSize, fps: Int, transform: CGAffineTransform, audioSettings: [String: Any]?, context: CIContext) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EMU-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                // About 30 Mbps at 1080p24, twice a phone's default, so moving grain survives compression.
                AVVideoAverageBitRateKey: Int(size.width * size.height) * fps * 6 / 10,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        video.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(video) else { return nil }
        writer.add(video)

        var audio: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }
        guard writer.startWriting() else { return nil }

        self.size = size
        self.writer = writer
        self.video = video
        self.adaptor = adaptor
        self.audio = audio
        self.context = context
        self.url = url
    }

    /// Renders `image` (at `size`, origin zero) into a new frame and appends it.
    /// Returns the frame, for the viewfinder to show exactly what was recorded.
    func append(_ image: CIImage, at time: CMTime) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !finishing, writer.status == .writing else { return nil }
        if !started {
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        var buffer: CVPixelBuffer?
        if video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        guard let buffer else {
            dropped += 1
            return nil
        }
        let destination = CIRenderDestination(pixelBuffer: buffer)
        destination.colorSpace = Self.colorSpace
        _ = try? context.startTask(toRender: image, to: destination).waitUntilCompleted()
        if adaptor.append(buffer, withPresentationTime: time) {
            frames += 1
            latest = buffer
        } else {
            dropped += 1
        }
        return buffer
    }

    func append(audio sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard started, !finishing, let audio, audio.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= startTime else { return }
        audio.append(sample)
    }

    /// Calls back on the main queue with whether the clip made it into Photos.
    func finish(completion: @escaping (Bool) -> Void) {
        lock.lock()
        finishing = true
        let started = self.started
        lock.unlock()
        let done: (Bool) -> Void = { ok in DispatchQueue.main.async { completion(ok) } }

        guard started else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return done(false)
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting { [writer, url] in
            guard writer.status == .completed else { return done(false) }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else { return done(false) }
                PHPhotoLibrary.shared().performChanges({
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
                }, completionHandler: { ok, _ in done(ok) })
            }
        }
    }
}
