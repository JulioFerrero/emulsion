import UIKit

final class ShutterButton: UIControl {
    private let ring = CAShapeLayer()
    private let core = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 3
        core.backgroundColor = UIColor.white.cgColor
        layer.addSublayer(ring)
        layer.addSublayer(core)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Red core for video; while recording it becomes a small square, the universal stop.
    var isVideo = false {
        didSet { updateCore() }
    }

    var isRecording = false {
        didSet { updateCore() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateCore()
        CATransaction.commit()
    }

    private func updateCore() {
        let inner = bounds.insetBy(dx: 8, dy: 8)
        let side = isRecording ? inner.width * 0.45 : inner.width
        core.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        core.position = CGPoint(x: bounds.midX, y: bounds.midY)
        core.cornerRadius = isRecording ? 5 : side / 2
        core.backgroundColor = isVideo ? UIColor(red: 0.93, green: 0.22, blue: 0.17, alpha: 1).cgColor : UIColor.white.cgColor
    }

    override var isHighlighted: Bool {
        didSet {
            CATransaction.begin()
            CATransaction.setAnimationDuration(isHighlighted ? 0.06 : 0.18)
            core.transform = isHighlighted ? CATransform3DMakeScale(0.88, 0.88, 1) : CATransform3DIdentity
            core.opacity = isHighlighted ? 0.75 : 1
            CATransaction.commit()
        }
    }
}
