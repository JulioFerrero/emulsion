import UIKit

/// A small glass label over the viewfinder: HOLD while a burst exposes, REC with timecode, EV while dragging.
final class GlassPill: UIVisualEffectView {
    private let label = UILabel()

    init() {
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        clipsToBounds = true
        isUserInteractionEnabled = false
        alpha = 0
        label.textAlignment = .center
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        label.frame = contentView.bounds
    }

    var isShowing: Bool { alpha > 0 }

    func show(_ text: NSAttributedString) {
        label.attributedText = text
        guard alpha < 1 else { return }
        layer.removeAllAnimations()
        transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.15) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    func hide(after delay: TimeInterval = 0.1) {
        UIView.animate(withDuration: 0.25, delay: delay, options: [.beginFromCurrentState]) { self.alpha = 0 }
    }
}
