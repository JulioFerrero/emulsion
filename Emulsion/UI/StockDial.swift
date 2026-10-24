import UIKit

/// Film stocks in a row like the system camera's mode switcher: swipe or tap to pick one.
final class StockDial: UIView {
    var onSelect: ((Int) -> Void)?
    private(set) var selectedIndex = 0

    private let labels: [UILabel]
    private let fade = CAGradientLayer()
    private let spacing: CGFloat = 26
    private var dragOffset: CGFloat = 0

    init(titles: [String]) {
        labels = titles.map { title in
            let label = UILabel()
            label.attributedText = NSAttributedString(string: title, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
                .kern: 1.5,
                .foregroundColor: UIColor.white,
            ])
            label.sizeToFit()
            return label
        }
        super.init(frame: .zero)
        labels.forEach(addSubview)

        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        fade.locations = [0, 0.18, 0.82, 1]
        layer.mask = fade

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func select(_ index: Int, animated: Bool) {
        selectedIndex = index
        dragOffset = 0
        if animated {
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                self.positionLabels()
            }
        } else {
            positionLabels()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fade.frame = bounds
        positionLabels()
    }

    private var centers: [CGFloat] {
        var x: CGFloat = 0
        return labels.map { label in
            defer { x += label.bounds.width + spacing }
            return x + label.bounds.width / 2
        }
    }

    private func positionLabels() {
        let centers = self.centers
        let offset = bounds.midX - centers[selectedIndex] + dragOffset
        for (i, label) in labels.enumerated() {
            label.center = CGPoint(x: (centers[i] + offset).rounded(), y: bounds.midY)
            label.alpha = i == selectedIndex ? 1 : 0.35
        }
    }

    private func choose(_ index: Int) {
        let changed = index != selectedIndex
        select(index, animated: true)
        if changed {
            onSelect?(index)
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: self).x
        let nearest = labels.indices.min { abs(labels[$0].center.x - x) < abs(labels[$1].center.x - x) }
        if let nearest {
            choose(nearest)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed:
            dragOffset = gesture.translation(in: self).x
            positionLabels()
        case .ended, .cancelled:
            let nearest = labels.indices.min { abs(labels[$0].center.x - bounds.midX) < abs(labels[$1].center.x - bounds.midX) }
            choose(nearest ?? selectedIndex)
        default:
            break
        }
    }
}
