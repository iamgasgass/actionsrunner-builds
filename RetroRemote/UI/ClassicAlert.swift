import UIKit

private final class AlertDimView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = hypot(bounds.width, bounds.height) / 2
        ctx.drawRadialGradient(Draw.gradient([UIColor(0, 0, 0, 0.3), UIColor(0, 0, 0, 0.75)]),
                               startCenter: c, startRadius: 0, endCenter: c, endRadius: radius,
                               options: [.drawsAfterEndLocation])
    }
}

private final class AlertBoxView: ThemedView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = UIBezierPath(roundedRect: r, cornerRadius: 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: UIColor(0, 0, 0, 0.65).cgColor)
        p.alertFill.setFill()
        path.fill()
        ctx.restoreGState()
        ctx.saveGState()
        path.addClip()
        let gloss = UIBezierPath(ovalIn: CGRect(x: r.minX - r.width * 0.35, y: r.minY - 62, width: r.width * 1.7, height: 104))
        Draw.fillVertical(gloss, CGRect(x: r.minX, y: r.minY, width: r.width, height: 42),
                          [UIColor(255, 255, 255, 0.3), UIColor(255, 255, 255, 0.08)])
        ctx.restoreGState()
        p.alertBorder.setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}

private final class AlertButton: UIControl {
    let isCancel: Bool
    private let title: String

    init(title: String, cancel: Bool) {
        self.title = title
        self.isCancel = cancel
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var isHighlighted: Bool { didSet { setNeedsDisplay() } }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = UIBezierPath(roundedRect: r, cornerRadius: 6)
        if isHighlighted {
            Draw.fillVertical(path, r, [UIColor(120, 168, 255, 0.95), UIColor(36, 86, 216, 0.95)])
        } else if isCancel {
            UIColor(0, 0, 0, 0.3).setFill()
            path.fill()
        } else {
            UIColor(255, 255, 255, 0.06).setFill()
            path.fill()
        }
        ctx.saveGState()
        path.addClip()
        let top = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height / 2)
        Draw.fillVertical(UIBezierPath(rect: top), top, [UIColor(255, 255, 255, 0.34), UIColor(255, 255, 255, 0.14)])
        ctx.restoreGState()
        UIColor(0, 0, 0, 0.6).setStroke()
        path.lineWidth = 1
        path.stroke()
        let hl = UIBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 5)
        UIColor(255, 255, 255, 0.18).setStroke()
        hl.lineWidth = 1
        hl.stroke()
        Draw.text(title, font: Fonts.bold(18), color: .white, shadow: UIColor(0, 0, 0, 0.6),
                  offset: CGSize(width: 0, height: -1), in: r)
    }
}

private final class AlertFieldView: UIView {
    let field = UITextField()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        field.font = Fonts.regular(16)
        field.textColor = .black
        field.borderStyle = .none
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.keyboardAppearance = .dark
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.frame = bounds.insetBy(dx: 7, dy: 3)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = UIBezierPath(roundedRect: r, cornerRadius: 4)
        UIColor.white.setFill()
        path.fill()
        ctx.saveGState()
        path.addClip()
        let shade = CGRect(x: r.minX, y: r.minY, width: r.width, height: 6)
        Draw.fillVertical(UIBezierPath(rect: shade), shade, [UIColor(0, 0, 0, 0.28), UIColor(0, 0, 0, 0)])
        ctx.restoreGState()
        UIColor(40, 40, 40).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// UIAlertView di iOS 6: riquadro blu traslucido con riflesso, animazione "pop" e campi di testo.
final class ClassicAlertController: UIViewController, UITextFieldDelegate {
    enum ActionStyle { case normal, cancel }

    struct Action {
        let title: String
        let style: ActionStyle
        let handler: ((ClassicAlertController) -> Void)?
    }

    private let alertTitle: String?
    private let message: String?
    private var actions: [Action] = []
    private var fieldSpecs: [(placeholder: String, text: String?, keyboard: UIKeyboardType)] = []
    private(set) var textFields: [UITextField] = []

    private let dimView = AlertDimView()
    private let box = AlertBoxView()

    init(title: String?, message: String?) {
        alertTitle = title
        self.message = message
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    func addAction(_ title: String, style: ActionStyle = .normal, handler: ((ClassicAlertController) -> Void)? = nil) {
        actions.append(Action(title: title, style: style, handler: handler))
    }

    func addTextField(placeholder: String, text: String? = nil, keyboard: UIKeyboardType = .default) {
        fieldSpecs.append((placeholder, text, keyboard))
    }

    func show(from presenter: UIViewController) {
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        top.present(self, animated: false)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { Preferences.shared.hideStatusBar }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.alpha = 0
        view.addSubview(dimView)

        box.translatesAutoresizingMaskIntoConstraints = false
        box.alpha = 0
        view.addSubview(box)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        if let t = alertTitle {
            stack.addArrangedSubview(makeLabel(t, font: Fonts.bold(18)))
        }
        if let m = message {
            stack.addArrangedSubview(makeLabel(m, font: Fonts.regular(16)))
        }
        for spec in fieldSpecs {
            let container = AlertFieldView()
            container.field.placeholder = spec.placeholder
            container.field.text = spec.text
            container.field.keyboardType = spec.keyboard
            container.field.delegate = self
            container.field.returnKeyType = .done
            container.heightAnchor.constraint(equalToConstant: 31).isActive = true
            textFields.append(container.field)
            stack.addArrangedSubview(container)
        }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(16, after: last) }

        let buttons = actions.enumerated().map { index, action -> AlertButton in
            let b = AlertButton(title: action.title, cancel: action.style == .cancel)
            b.tag = index
            b.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            b.heightAnchor.constraint(equalToConstant: 43).isActive = true
            return b
        }
        if buttons.count == 2 {
            let row = UIStackView(arrangedSubviews: buttons)
            row.axis = .horizontal
            row.spacing = 9
            row.distribution = .fillEqually
            stack.addArrangedSubview(row)
        } else {
            buttons.forEach { stack.addArrangedSubview($0) }
        }

        let centerY = box.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -10)
        centerY.priority = .defaultHigh
        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            box.widthAnchor.constraint(equalToConstant: 288),
            centerY,
            box.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            box.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -15)
        ])
    }

    private func makeLabel(_ text: String, font: UIFont) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = font
        l.textColor = .white
        l.textAlignment = .center
        l.numberOfLines = 0
        l.shadowColor = UIColor(0, 0, 0, 0.6)
        l.shadowOffset = CGSize(width: 0, height: -1)
        return l
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        box.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        UIView.animate(withDuration: 0.16, delay: 0, options: .curveEaseOut, animations: {
            self.box.alpha = 1
            self.box.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
            self.dimView.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.1, animations: {
                self.box.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            }, completion: { _ in
                UIView.animate(withDuration: 0.08) { self.box.transform = .identity }
            })
        })
        textFields.first?.becomeFirstResponder()
    }

    private func close(then completion: @escaping () -> Void) {
        view.endEditing(true)
        UIView.animate(withDuration: 0.2, animations: {
            self.box.alpha = 0
            self.dimView.alpha = 0
            self.box.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        }, completion: { _ in
            self.dismiss(animated: false, completion: completion)
        })
    }

    @objc private func buttonTapped(_ sender: UIControl) {
        let action = actions[sender.tag]
        Feedback.tap()
        close { action.handler?(self) }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let index = textFields.firstIndex(of: textField), index + 1 < textFields.count {
            textFields[index + 1].becomeFirstResponder()
            return false
        }
        if let action = actions.last(where: { $0.style != .cancel }) {
            close { action.handler?(self) }
        }
        return false
    }
}
