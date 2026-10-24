import CoreImage
import CoreMedia
import CoreVideo

/// Virtual ND: the sensor runs at 120 fps with exposures as short as the light demands, and the frames that
/// fall inside each output frame's shutter window are averaged into it. A 180° shutter's motion blur in full
/// sun, with no filter on the lens. In very bright light each sensor frame is far shorter than 1/120, so fast
/// motion blurs as a few overlapping copies rather than one smooth streak. Video queue only.
final class FrameBlender {
    private let context: CIContext
    private var buffers: [CVPixelBuffer] = []
    private var size = CGSize.zero
    /// The buffer the running sum lives in, and the one the last finished frame still reads.
    private var current: Int?
    private var held: Int?
    private var sum: CIImage?
    private var count = 0
    private var frameIndex = -1
    private var origin = CMTime.invalid
    private var last = CMTime.invalid

    init(context: CIContext) {
        self.context = context
    }

    /// Adds a sensor frame (scene-linear, origin zero) captured at `time` by a sensor running at `sensorFPS`.
    /// `window` is the shutter's open share of each output frame. Returns the previous output frame and its
    /// time once `time` starts a new one.
    func add(_ image: CIImage, at time: CMTime, fps: Int, sensorFPS: Int, window: Double) -> (image: CIImage, time: CMTime)? {
        if image.extent.size != size {
            size = image.extent.size
            buffers = (0..<3).compactMap { _ in Self.makeBuffer(size) }
            reset()
        }
        // A gap means the blend was off or the camera paused: start over rather than finish a stale frame.
        if !last.isValid || (time - last).seconds > 0.1 || time < last {
            reset()
        }
        last = time
        guard buffers.count == 3 else { return nil }
        if !origin.isValid {
            origin = time
        }
        // Half a sensor frame of slack, so a frame landing right on a boundary goes to the one it starts.
        let elapsed = (time - origin).seconds + 0.5 / Double(sensorFPS)
        let index = Int((elapsed * Double(fps)).rounded(.down))
        var finished: (CIImage, CMTime)?
        if index != frameIndex {
            if let sum, count > 0 {
                let scale = CGFloat(1) / CGFloat(count)
                let average = sum.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                ])
                finished = (average, origin + CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)))
                held = current
            }
            sum = nil
            current = nil
            count = 0
            frameIndex = index
        }
        // As many sensor frames as the shutter is open for, from the start of each output frame.
        let open = max(1, Int((window * Double(sensorFPS) / Double(fps)).rounded()))
        if count < open {
            let total = sum.flatMap { FilmKernels.addFrames.apply(extent: image.extent, arguments: [$0, image]) } ?? image
            // The camera wants its buffer back, so even the first frame is copied out; never into the
            // buffer being read from, or the one the last finished frame is still drawn from.
            guard let free = buffers.indices.first(where: { $0 != current && $0 != held }) else { return finished }
            let destination = CIRenderDestination(pixelBuffer: buffers[free])
            destination.colorSpace = nil
            _ = try? context.startTask(toRender: total, to: destination).waitUntilCompleted()
            sum = CIImage(cvPixelBuffer: buffers[free], options: [.colorSpace: NSNull()])
            current = free
            count += 1
        }
        return finished
    }

    private func reset() {
        sum = nil
        current = nil
        held = nil
        count = 0
        frameIndex = -1
        origin = .invalid
    }

    private static func makeBuffer(_ size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_64RGBAHalf, attributes as CFDictionary, &buffer)
        return buffer
    }
}
