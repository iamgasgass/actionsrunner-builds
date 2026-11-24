import UIKit

/// Pulsante della navigation bar iOS 6: normale, "Fine" blu o "Indietro" a freccia.
final class ClassicBarButton: ThemedControl {
    enum Style { case plain, done, back }

    let style: Style
    private let label = UILabel()
    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let symbolName: String?

    var title: String? {
        didSet {
            label.text = title
            invalidateIntrinsicContentSize()
            superview?.setNeedsLayout()
        }
    }

    var isSpinning = false {
        didSet {
            label.alpha = isSpinning ? 0 : 1
            iconView.alpha = isSpinning ? 0 : 1
            if isSpinning { spinner.startAnimating() } else { spinner.stopAnimating() }
        }
    }

    init(title: String? = nil, symbol: String? = nil, style: Style = .plain) {
        self.style = style
        self.symbolName = symbol
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        label.font = Fonts.bold(12)
        label.textColor = .white
        label.shadowColor = UIColor(0, 0, 0, 0.5)
        label.shadowOffset = CGSize(width: 0, height: -1)
        label.textAlignment = .center
        label.text = title
        self.title = title
        iconView.contentMode = .center
        if let symbol = symbol {
            iconView.image = Draw.symbol(symbol, pointSize: 14, weight: .heavy, color: .white)
            iconView.layer.shadowColor = UIColor.black.cgColor
            iconView.layer.shadowOpacity = 0.5
            iconView.layer.shadowRadius = 0
            iconView.layer.shadowOffset = CGSize(width: 0, height: -1)
        }
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        addSubview(label)
        addSubview(iconView)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var intrinsicContentSize: CGSize {
        var width: CGFloat
        if let t = title, !t.isEmpty {
            width = ceil((t as NSString).size(withAttributes: [.font: Fonts.bold(12)]).width) + 20
        } else {
            width = 36
        }
        if style == .back { width += 6 }
        return CGSize(width: max(width, style == .back ? 50 : 36), height: 30)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }
    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.5 } }

    override func layoutSubviews() {
        super.layoutSubviews()
        var content = bounds
        content.size.height -= 1
        if style == .back { content.origin.x += 6; content.size.width -= 6 }
        label.frame = content.insetBy(dx: 4, dy: 0)
        iconView.frame = content
        spinner.center = CGPoint(x: content.midX, y: content.midY)
    }

    private func shape(in r: CGRect, radius: CGFloat) -> UIBezierPath {
        guard style == .back else { return UIBezierPath(roundedRect: r, cornerRadius: radius) }
        let arrow = r.height * 0.36
        let path = UIBezierPath()
        path.move(to: CGPoint(x: r.minX, y: r.midY))
        path.addLine(to: CGPoint(x: r.minX + arrow, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        path.addArc(withCenter: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius,
                    startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        path.addArc(withCenter: CGPoint(x: r.maxX - radius, y: r.maxY - radius), radius: radius,
                    startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: r.minX + arrow, y: r.maxY))
        path.close()
        return path
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        var r = bounds
        r.size.height -= 1

        p.barButtonGlow.setFill()
        shape(in: r.offsetBy(dx: 0, dy: 1), radius: 5).fill()

        (style == .done ? p.doneBorder : p.barButtonBorder).setFill()
        shape(in: r, radius: 5).fill()

        let inner = r.insetBy(dx: 1, dy: 1)
        let body = shape(in: inner, radius: 4)
        var colors = style == .done ? [p.doneTop, p.doneBottom] : [p.barButtonTop, p.barButtonBottom]
        if isHighlighted { colors = colors.map { $0.scaled(0.72) } }
        Draw.fillVertical(body, inner, colors)

        ctx.saveGState()
        body.addClip()
        let gloss = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height / 2)
        ctx.setFillColor(UIColor(255, 255, 255, isHighlighted ? 0.03 : 0.08).cgColor)
        ctx.fill(gloss)
        ctx.setFillColor(UIColor(255, 255, 255, 0.22).cgColor)
        ctx.fill(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 1))
        ctx.restoreGState()
    }
}
