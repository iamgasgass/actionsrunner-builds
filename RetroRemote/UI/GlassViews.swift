import UIKit

/// Superficie "Liquid Glass": UIGlassEffect su iOS 26, materiale traslucido sulle versioni precedenti.
final class GlassView: UIView {
    let effectView = UIVisualEffectView(effect: nil)

    var cornerRadius: CGFloat {
        didSet { applyCorner() }
    }

    var tint: UIColor? {
        didSet { applyEffect() }
    }

    var contentView: UIView { effectView.contentView }

    init(cornerRadius: CGFloat = 16, tint: UIColor? = nil) {
        self.cornerRadius = cornerRadius
        self.tint = tint
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        effectView.frame = bounds
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(effectView)
        applyEffect()
        applyCorner()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    private func applyEffect() {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.tintColor = tint
            effectView.effect = glass
        } else {
            effectView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            effectView.contentView.backgroundColor = tint?.withAlphaComponent(0.45)
                ?? UIColor { $0.userInterfaceStyle == .dark ? UIColor(255, 255, 255, 0.06) : UIColor(255, 255, 255, 0.35) }
            effectView.layer.borderWidth = 0.75
            effectView.layer.borderColor = UIColor(255, 255, 255, 0.28).cgColor
        }
    }

    private func applyCorner() {
        effectView.layer.cornerRadius = cornerRadius
        effectView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
    }
}

/// Sfondo sfumato dietro le superfici di vetro (serve a dare "materia" alla rifrazione).
final class GlassBackdropView: UIView {
    private let base = CAGradientLayer()
    private let blobA = CAGradientLayer()
    private let blobB = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        [base, blobA, blobB].forEach { layer.addSublayer($0) }
        blobA.type = .radial
        blobB.type = .radial
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func layoutSubviews() {
        super.layoutSubviews()
        base.frame = bounds
        let side = max(bounds.width, bounds.height)
        blobA.frame = CGRect(x: -side * 0.35, y: -side * 0.2, width: side * 0.9, height: side * 0.9)
        blobB.frame = CGRect(x: bounds.width - side * 0.45, y: bounds.height - side * 0.55, width: side * 0.9, height: side * 0.9)
        for blob in [blobA, blobB] {
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        base.colors = dark
            ? [UIColor(18, 22, 36).cgColor, UIColor(6, 7, 12).cgColor]
            : [UIColor(236, 241, 250).cgColor, UIColor(208, 216, 232).cgColor]
        let a = dark ? UIColor(64, 92, 220, 0.55) : UIColor(120, 160, 255, 0.45)
        let b = dark ? UIColor(150, 60, 190, 0.40) : UIColor(255, 150, 190, 0.40)
        blobA.colors = [a.cgColor, a.withAlphaComponent(0).cgColor]
        blobB.colors = [b.cgColor, b.withAlphaComponent(0).cgColor]
    }
}

/// Pulsante circolare di vetro (usato per il menu "…").
final class GlassCircleButton: UIButton {
    private let glass = GlassView(cornerRadius: 19)
    private let side: CGFloat

    init(symbol: String, side: CGFloat = 38) {
        self.side = side
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        insertSubview(glass, at: 0)
        setImage(systemSymbol(symbol, size: 16, weight: .bold), for: .normal)
        tintColor = .label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var intrinsicContentSize: CGSize { CGSize(width: side, height: side) }
    override func sizeThatFits(_ size: CGSize) -> CGSize { intrinsicContentSize }

    override var isHighlighted: Bool {
        didSet { animatePress(self, pressed: isHighlighted) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        if let imageView = imageView { bringSubviewToFront(imageView) }
    }
}

/// Pulsante della navigation bar iOS 6 che apre un UIMenu (menu "…").
final class ClassicMenuButton: UIButton {
    private let face: ClassicBarButton

    init(title: String? = nil, symbol: String? = nil) {
        face = ClassicBarButton(title: title, symbol: symbol)
        super.init(frame: .zero)
        face.isUserInteractionEnabled = false
        addSubview(face)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var intrinsicContentSize: CGSize { face.intrinsicContentSize }
    override func sizeThatFits(_ size: CGSize) -> CGSize { face.intrinsicContentSize }

    override var isHighlighted: Bool {
        didSet { face.isHighlighted = isHighlighted }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        face.frame = bounds
    }
}

/// Barra delle modalità Liquid Glass: capsula di vetro con indicatore della modalità attiva.
final class GlassModeBar: UIView {
    var onSelect: ((Int) -> Void)?
    private let glass = GlassView(cornerRadius: 31)
    private let indicator = UIView()
    private var buttons: [UIButton] = []

    var selectedIndex = 0 {
        didSet { updateSelection(animated: true) }
    }

    init(items: [(title: String, symbol: String)]) {
        super.init(frame: .zero)
        addSubview(glass)
        indicator.backgroundColor = UIColor.label.withAlphaComponent(0.12)
        indicator.layer.cornerCurve = .continuous
        indicator.isUserInteractionEnabled = false
        addSubview(indicator)
        for (index, item) in items.enumerated() {
            let button = UIButton(type: .system)
            button.setImage(systemSymbol(item.symbol, size: 20, weight: .semibold), for: .normal)
            button.accessibilityLabel = item.title
            button.tag = index
            button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            addSubview(button)
            buttons.append(button)
        }
        updateSelection(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    @objc private func tapped(_ sender: UIButton) {
        Feedback.selection()
        onSelect?(sender.tag)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.cornerRadius = bounds.height / 2
        let inset: CGFloat = 6
        let width = (bounds.width - inset * 2) / CGFloat(max(buttons.count, 1))
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: inset + width * CGFloat(index), y: inset, width: width, height: bounds.height - inset * 2)
        }
        updateSelection(animated: false)
    }

    private func updateSelection(animated: Bool) {
        for (index, button) in buttons.enumerated() {
            button.tintColor = index == selectedIndex ? .label : .secondaryLabel
        }
        guard buttons.indices.contains(selectedIndex) else { return }
        let frame = buttons[selectedIndex].frame
        let apply = {
            self.indicator.frame = frame
            self.indicator.layer.cornerRadius = frame.height / 2
        }
        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState], animations: apply)
        } else {
            apply()
        }
    }
}

/// Animazione di pressione per i controlli di vetro.
func animatePress(_ view: UIView, pressed: Bool) {
    UIView.animate(withDuration: pressed ? 0.08 : 0.3, delay: 0, usingSpringWithDamping: pressed ? 1 : 0.55,
                   initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
        view.transform = pressed ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
    }
}

/// Pulsante di vetro con testo (es. "Tocca per connetterti"), opzionalmente colorato.
final class GlassTextButton: UIControl {
    private let glass: GlassView
    let label = UILabel()
    private let icon = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(tint: UIColor? = nil) {
        glass = GlassView(cornerRadius: 22, tint: tint)
        super.init(frame: .zero)
        addSubview(glass)
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.textColor = tint == nil ? .label : .white
        icon.tintColor = label.textColor
        icon.contentMode = .center
        spinner.hidesWhenStopped = true
        spinner.color = label.textColor
        addSubview(icon)
        addSubview(label)
        addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    func configure(title: String, symbol: String?, spinning: Bool) {
        label.text = title
        icon.image = symbol.flatMap { systemSymbol($0, size: 16, weight: .semibold) }
        if spinning { spinner.startAnimating() } else { spinner.stopAnimating() }
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet { animatePress(self, pressed: isHighlighted) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.cornerRadius = min(22, bounds.height / 2)
        let textWidth = min(bounds.width - 60, ceil(label.sizeThatFits(bounds.size).width))
        let hasAccessory = icon.image != nil || spinner.isAnimating
        let total = textWidth + (hasAccessory ? 26 : 0)
        var x = (bounds.width - total) / 2
        if hasAccessory {
            icon.frame = CGRect(x: x, y: 0, width: 20, height: bounds.height)
            spinner.center = CGPoint(x: x + 10, y: bounds.midY)
            icon.isHidden = spinner.isAnimating
            x += 26
        }
        label.frame = CGRect(x: x, y: 0, width: textWidth, height: bounds.height)
    }
}
