import UIKit

/// A focus ring laid flat along the bottom of the viewfinder: drag it like turning a lens barrel.
/// Close focus sits to the left, infinity to the right, and the scale moves under your finger.
final class FocusRing: UIView {
    /// New lens position while turning.
    var onChange: ((Float) -> Void)?
    /// True while a finger is on the ring.
    var onTurning: ((Bool) -> Void)?
    private(set) var position: Float = FocusScale.position(meters: 2)

    private let shade = CAGradientLayer()
    private let ticks = CAShapeLayer()
    private let index = CALayer()
    private let readout = UILabel()
    private var marks: [(position: Float, layer: CATextLayer)] = []
    private var startPosition: Float = 0

    /// Points of travel per unit of lens position.
    private static let travel: CGFloat = 1500
    private static let markedDistances: [Float] = [0.1, 0.15, 0.2, 0.3, 0.5, 1, 2, 5]

    override init(frame: CGRect) {
        super.init(frame: frame)
        shade.colors = [UIColor.clear, UIColor.black.withAlphaComponent(0.6)].map(\.cgColor)
        layer.addSublayer(shade)

        ticks.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
        ticks.lineWidth = 1
        layer.addSublayer(ticks)

        let font = UIFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        for meters in Self.markedDistances {
            marks.append((FocusScale.position(meters: meters), textLayer(meters < 1 ? String(format: "%.2g", meters) : "\(Int(meters))", font: font)))
        }
        marks.append((FocusScale.infinity, textLayer("∞", font: font)))

        index.backgroundColor = UIColor(red: 1, green: 0.72, blue: 0.3, alpha: 1).cgColor
        layer.addSublayer(index)

        readout.textAlignment = .center
        addSubview(readout)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func set(_ position: Float) {
        self.position = min(max(position, 0), 1)
        redraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shade.frame = bounds
        index.frame = CGRect(x: bounds.midX - 0.5, y: bounds.height - 26, width: 1, height: 18)
        readout.frame = CGRect(x: 0, y: bounds.height - 48, width: bounds.width, height: 18)
        redraw()
    }

    private func textLayer(_ text: String, font: UIFont) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: UIColor.white.withAlphaComponent(0.8),
        ])
        layer.contentsScale = UIScreen.main.scale
        layer.alignmentMode = .center
        layer.bounds = CGRect(x: 0, y: 0, width: 32, height: 12)
        self.layer.addSublayer(layer)
        return layer
    }

    private func x(for lens: Float) -> CGFloat {
        bounds.midX + CGFloat(lens - position) * Self.travel
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = UIBezierPath()
        let baseline = bounds.height - 8
        for step in 0...100 {
            let lens = Float(step) / 100
            let x = x(for: lens)
            guard x > -2, x < bounds.width + 2 else { continue }
            let height: CGFloat = step % 5 == 0 ? 10 : 5
            path.move(to: CGPoint(x: x, y: baseline))
            path.addLine(to: CGPoint(x: x, y: baseline - height))
        }
        ticks.path = path.cgPath
        for mark in marks {
            mark.layer.position = CGPoint(x: x(for: mark.position), y: baseline - 18)
        }
        readout.attributedText = NSAttributedString(string: "≈ " + FocusScale.label(position), attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .kern: 1.2,
            .foregroundColor: UIColor.white,
        ])
        CATransaction.commit()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            startPosition = position
            onTurning?(true)
        case .changed:
            set(startPosition - Float(gesture.translation(in: self).x / Self.travel))
            onChange?(position)
        default:
            onTurning?(false)
        }
    }
}
