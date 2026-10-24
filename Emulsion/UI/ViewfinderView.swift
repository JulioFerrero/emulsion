import CoreImage
import Metal
import UIKit

/// Draws film-rendered frames straight into a Metal layer, from any thread.
final class ViewfinderView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
    private let sizeLock = NSLock()
    private var currentDrawableSize: CGSize = .zero

    override init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        commandQueue = device?.makeCommandQueue()
        context = device.map {
            CIContext(mtlDevice: $0, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        }
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Pixel size frames should be scaled to before calling `display`.
    var drawableSize: CGSize {
        sizeLock.lock()
        defer { sizeLock.unlock() }
        return currentDrawableSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalLayer.drawableSize = size
        sizeLock.lock()
        currentDrawableSize = size
        sizeLock.unlock()
    }

    /// `image` must already be scaled to `drawableSize` with its origin at zero.
    func display(_ image: CIImage) {
        guard let context, let commandQueue, let colorSpace,
              let drawable = metalLayer.nextDrawable(),
              let buffer = commandQueue.makeCommandBuffer() else { return }
        let bounds = CGRect(x: 0, y: 0, width: drawable.texture.width, height: drawable.texture.height)
        context.render(image, to: drawable.texture, commandBuffer: buffer, bounds: bounds, colorSpace: colorSpace)
        buffer.present(drawable)
        buffer.commit()
    }
}
