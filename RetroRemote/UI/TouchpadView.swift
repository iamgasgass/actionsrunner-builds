import UIKit

/// Superficie a sfioramento: scorri per le frecce, tocca per OK, due dita per Indietro.
/// Con le TV che lo supportano (LG) può muovere il puntatore come un mouse.
final class TouchpadView: ThemedView {
    var onKey: ((RemoteKey) -> Void)?
    var onPointerMove: ((Int, Int) -> Void)?
    var onPointerClick: (() -> Void)?
    var pointerMode = false { didSet { setNeedsDisplay(); updateGlassHints() } }

    private let glassMode = InterfaceStyle.isGlass
    private var glass: GlassView?
    private let hintLabel = UILabel()
    private let subHintLabel = UILabel()
    private let glow = UIView()

    private var anchor: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var touchPoint: CGPoint?
    private let step: CGFloat = 38

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFinger.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFinger)

        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        long.minimumPressDuration = 0.6
        addGestureRecognizer(long)
        tap.require(toFail: long)

        if glassMode {
            let g = GlassView(cornerRadius: 28)
            glass = g
            addSubview(g)
            glow.backgroundColor = UIColor.label.withAlphaComponent(0.16)
            glow.isUserInteractionEnabled = false
            glow.isHidden = true
            addSubview(glow)
            hintLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            subHintLabel.font = .systemFont(ofSize: 13)
            [hintLabel, subHintLabel].forEach {
                $0.textAlignment = .center
                $0.numberOfLines = 0
                $0.textColor = .secondaryLabel
                addSubview($0)
            }
            updateGlassHints()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let g = glass else { return }
        g.frame = bounds.insetBy(dx: 2, dy: 2)
        hintLabel.frame = CGRect(x: 16, y: bounds.midY - 26, width: bounds.width - 32, height: 24)
        subHintLabel.frame = CGRect(x: 16, y: bounds.midY + 2, width: bounds.width - 32, height: 36)
    }

    private func updateGlassHints() {
        guard glassMode else { return }
        hintLabel.text = pointerMode ? "Muovi il puntatore · Tocca per cliccare" : "Scorri per muoverti · Tocca per OK"
        subHintLabel.text = "Due dita: Indietro · Tieni premuto: Menu"
    }

    private func showGlow(at point: CGPoint?) {
        guard glassMode else { return }
        guard let p = point else {
            UIView.animate(withDuration: 0.2) { self.glow.alpha = 0 } completion: { _ in self.glow.isHidden = true }
            return
        }
        glow.frame = CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60)
        glow.layer.cornerRadius = 30
        glow.alpha = 1
        glow.isHidden = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        flash(at: gesture.location(in: self))
        if pointerMode, let click = onPointerClick {
            Feedback.tap()
            click()
        } else {
            fire(.ok)
        }
    }

    @objc private func handleTwoFingerTap() { fire(.back) }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { fire(.menu) }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            anchor = point
            lastPoint = point
            touchPoint = point
        case .changed:
            touchPoint = point
            if pointerMode, let move = onPointerMove {
                let dx = Int((point.x - lastPoint.x) * 1.6)
                let dy = Int((point.y - lastPoint.y) * 1.6)
                if dx != 0 || dy != 0 { move(dx, dy) }
                lastPoint = point
            } else {
                let dx = point.x - anchor.x
                let dy = point.y - anchor.y
                if abs(dx) >= step || abs(dy) >= step {
                    if abs(dx) > abs(dy) {
                        fire(dx > 0 ? .right : .left)
                    } else {
                        fire(dy > 0 ? .down : .up)
                    }
                    anchor = point
                }
            }
        default:
            touchPoint = nil
        }
        setNeedsDisplay()
        showGlow(at: touchPoint)
    }

    private func fire(_ key: RemoteKey) {
        Feedback.tap()
        onKey?(key)
    }

    private func flash(at point: CGPoint) {
        touchPoint = point
        setNeedsDisplay()
        showGlow(at: point)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.touchPoint = nil
            self?.setNeedsDisplay()
            self?.showGlow(at: nil)
        }
    }

    override func draw(_ rect: CGRect) {
        guard !glassMode, let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let r = bounds.insetBy(dx: 2, dy: 2)
        let path = UIBezierPath(roundedRect: r, cornerRadius: 14)

        // Bordo inferiore chiaro (incavo)
        UIColor(255, 255, 255, p.isDark ? 0.08 : 0.7).setFill()
        UIBezierPath(roundedRect: r.offsetBy(dx: 0, dy: 1), cornerRadius: 14).fill()

        let colors = p.isDark
            ? [UIColor(10, 10, 12), UIColor(28, 29, 32)]
            : [UIColor(150, 154, 162), UIColor(186, 190, 197)]
        Draw.fillVertical(path, r, colors)

        // Ombra interna
        ctx.saveGState()
        path.addClip()
        let shade = CGRect(x: r.minX, y: r.minY, width: r.width, height: 14)
        Draw.fillVertical(UIBezierPath(rect: shade), shade, [UIColor(0, 0, 0, 0.45), UIColor(0, 0, 0, 0)])
        // Griglia di puntini
        ctx.setFillColor(UIColor(255, 255, 255, p.isDark ? 0.05 : 0.18).cgColor)
        var y = r.minY + 12
        while y < r.maxY {
            var x = r.minX + 12
            while x < r.maxX {
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                x += 12
            }
            y += 12
        }
        if let t = touchPoint {
            let glow = CGRect(x: t.x - 34, y: t.y - 34, width: 68, height: 68)
            ctx.drawRadialGradient(Draw.gradient([UIColor(120, 190, 255, 0.55), UIColor(120, 190, 255, 0)]),
                                   startCenter: t, startRadius: 0, endCenter: t, endRadius: glow.width / 2, options: [])
        }
        ctx.restoreGState()

        UIColor(0, 0, 0, p.isDark ? 0.9 : 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()

        let hint = pointerMode ? "Muovi il puntatore · Tocca per cliccare" : "Scorri per muoverti · Tocca per OK"
        Draw.text(hint, font: Fonts.bold(13), color: UIColor(255, 255, 255, p.isDark ? 0.35 : 0.75),
                  shadow: UIColor(0, 0, 0, 0.35), offset: CGSize(width: 0, height: -1),
                  in: CGRect(x: r.minX, y: r.midY - 20, width: r.width, height: 20))
        Draw.text("Due dita: Indietro · Tieni premuto: Menu", font: Fonts.regular(12),
                  color: UIColor(255, 255, 255, p.isDark ? 0.25 : 0.6),
                  in: CGRect(x: r.minX, y: r.midY + 2, width: r.width, height: 18))
    }
}
