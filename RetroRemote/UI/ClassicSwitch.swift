import UIKit

/// Interruttore iOS 6 (79×27) con le scritte "SÌ" / "NO" dell'edizione italiana.
final class ClassicSwitch: ThemedControl {
    static let size = CGSize(width: 79, height: 27)

    private(set) var isOn = false
    private var progress: CGFloat = 0 { didSet { setNeedsDisplay() } }

    private var trackStartX: CGFloat = 0
    private var trackStartProgress: CGFloat = 0
    private var moved = false

    private var link: CADisplayLink?
    private var animFrom: CGFloat = 0
    private var animTo: CGFloat = 0
    private var animStart: CFTimeInterval = 0

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: frame.origin, size: Self.size))
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var intrinsicContentSize: CGSize { Self.size }
    override func sizeThatFits(_ size: CGSize) -> CGSize { Self.size }

    func setOn(_ on: Bool, animated: Bool) {
        isOn = on
        if animated {
            animate(to: on ? 1 : 0)
        } else {
            link?.invalidate()
            link = nil
            progress = on ? 1 : 0
        }
    }

    private var travel: CGFloat { max(1, bounds.width - bounds.height) }

    private func animate(to target: CGFloat) {
        link?.invalidate()
        animFrom = progress
        animTo = target
        animStart = CACurrentMediaTime()
        let l = CADisplayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step() {
        let duration: CFTimeInterval = 0.2
        let t = min(1, (CACurrentMediaTime() - animStart) / duration)
        let eased = CGFloat(1 - pow(1 - t, 3))
        progress = animFrom + (animTo - animFrom) * eased
        if t >= 1 {
            link?.invalidate()
            link = nil
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        trackStartX = touch.location(in: self).x
        trackStartProgress = progress
        moved = false
        link?.invalidate()
        link = nil
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let dx = touch.location(in: self).x - trackStartX
        if abs(dx) > 3 { moved = true }
        if moved { progress = min(1, max(0, trackStartProgress + dx / travel)) }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let newValue = moved ? progress > 0.5 : !isOn
        let changed = newValue != isOn
        isOn = newValue
        animate(to: newValue ? 1 : 0)
        if changed {
            Feedback.selection()
            sendActions(for: .valueChanged)
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        animate(to: isOn ? 1 : 0)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let h = r.height
        let travel = r.width - h
        let knobX = r.minX + travel * progress
        let capsule = UIBezierPath(roundedRect: r, cornerRadius: h / 2)

        ctx.saveGState()
        capsule.addClip()
        let onRect = CGRect(x: knobX - travel, y: r.minY, width: travel + h / 2, height: h)
        Draw.fillVertical(UIBezierPath(rect: onRect), onRect,
                          [UIColor(0, 86, 196), UIColor(34, 128, 234), UIColor(96, 174, 252)], [0, 0.5, 1])
        let offRect = CGRect(x: knobX + h / 2, y: r.minY, width: travel + h / 2, height: h)
        Draw.fillVertical(UIBezierPath(rect: offRect), offRect, [p.switchOffTop, p.switchOffBottom])
        let shade = CGRect(x: r.minX, y: r.minY, width: r.width, height: h * 0.5)
        Draw.fillVertical(UIBezierPath(rect: shade), shade, [UIColor(0, 0, 0, 0.3), UIColor(0, 0, 0, 0)])
        Draw.text("SÌ", font: Fonts.bold(16), color: .white, shadow: UIColor(0, 0, 0, 0.45),
                  offset: CGSize(width: 0, height: -1),
                  in: CGRect(x: knobX - travel, y: r.minY, width: travel, height: h))
        Draw.text("NO", font: Fonts.bold(16), color: p.switchOffText, shadow: p.switchOffTextShadow,
                  offset: CGSize(width: 0, height: p.isDark ? -1 : 1),
                  in: CGRect(x: knobX + h, y: r.minY, width: travel, height: h))
        ctx.restoreGState()

        p.switchBorder.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        let kr = CGRect(x: knobX, y: r.minY, width: h, height: h).insetBy(dx: 0.5, dy: 0.5)
        let knob = UIBezierPath(ovalIn: kr)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 2, color: UIColor(0, 0, 0, 0.5).cgColor)
        p.knobBottom.setFill()
        knob.fill()
        ctx.restoreGState()
        Draw.fillVertical(knob, kr, [p.knobTop, p.knobBottom])
        p.knobBorder.setStroke()
        knob.lineWidth = 1
        knob.stroke()
    }
}
