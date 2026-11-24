import UIKit

/// Ripetizione automatica tenendo premuto (volume, frecce…).
final class KeyRepeater {
    private var timer: Timer?

    func start(_ action: @escaping () -> Void) {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            self?.timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in action() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }
}

/// Tasto fisico del telecomando: plastica lucida (tema chiaro) o vetro nero (tema scuro).
final class RemoteKeyButton: ThemedControl {
    enum Shape { case circle, rounded, pill }
    enum Tint { case normal, power, red, green, yellow, blue }

    let key: RemoteKey
    var shape: Shape
    var tint: Tint
    var title: String?
    var symbol: String?
    var symbolSize: CGFloat = 17
    var fontSize: CGFloat = 13
    var repeats = false
    var onPress: ((RemoteKey) -> Void)?

    private let repeater = KeyRepeater()

    init(key: RemoteKey, title: String? = nil, symbol: String? = nil,
         shape: Shape = .circle, tint: Tint = .normal, repeats: Bool = false) {
        self.key = key
        self.title = title
        self.symbol = symbol
        self.shape = shape
        self.tint = tint
        self.repeats = repeats
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isExclusiveTouch = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override var isHighlighted: Bool {
        didSet { if oldValue != isHighlighted { setNeedsDisplay() } }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isHighlighted = true
        fire()
        if repeats { repeater.start { [weak self] in self?.fire() } }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        repeater.stop()
        isHighlighted = false
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        repeater.stop()
        isHighlighted = false
        super.cancelTracking(with: event)
    }

    private func fire() {
        Feedback.tap()
        onPress?(key)
    }

    private func shapePath(_ r: CGRect) -> UIBezierPath {
        switch shape {
        case .circle:
            let d = min(r.width, r.height)
            return UIBezierPath(ovalIn: CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d))
        case .rounded:
            return UIBezierPath(roundedRect: r, cornerRadius: min(9, r.height / 3))
        case .pill:
            return UIBezierPath(roundedRect: r, cornerRadius: min(r.width, r.height) / 2)
        }
    }

    private var bodyColors: [UIColor] {
        let p = Theme.palette
        var colors: [UIColor]
        switch tint {
        case .normal:
            return isHighlighted ? [p.keyPressedTop, p.keyPressedBottom] : [p.keyTop, p.keyBottom]
        case .power: colors = [UIColor(242, 104, 92), UIColor(200, 40, 32), UIColor(150, 16, 12)]
        case .red: colors = [UIColor(244, 98, 88), UIColor(186, 28, 24)]
        case .green: colors = [UIColor(122, 214, 98), UIColor(36, 146, 40)]
        case .yellow: colors = [UIColor(255, 228, 96), UIColor(214, 164, 16)]
        case .blue: colors = [UIColor(98, 168, 252), UIColor(22, 86, 206)]
        }
        return isHighlighted ? colors.map { $0.scaled(0.72) } : colors
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let r = bounds.insetBy(dx: 3, dy: 3).offsetBy(dx: 0, dy: -1)
        let outer = shapePath(r)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: isHighlighted ? 1 : 2),
                      blur: isHighlighted ? 2 : 4, color: p.keyDropShadow.cgColor)
        (tint == .normal ? p.keyBorder : UIColor(0, 0, 0, 0.75)).setFill()
        outer.fill()
        ctx.restoreGState()

        let inner = r.insetBy(dx: 1, dy: 1)
        let body = shapePath(inner)
        Draw.fillVertical(body, inner, bodyColors)

        ctx.saveGState()
        body.addClip()
        if !isHighlighted {
            let gloss = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height * 0.5)
            let alpha = tint == .normal ? p.keyGloss : 0.35
            Draw.fillVertical(UIBezierPath(rect: gloss), gloss,
                              [UIColor(255, 255, 255, alpha), UIColor(255, 255, 255, alpha * 0.25)])
        }
        ctx.restoreGState()

        let highlight = shapePath(inner.insetBy(dx: 0.5, dy: 0.5))
        UIColor(255, 255, 255, isHighlighted ? 0.05 : 0.2).setStroke()
        highlight.lineWidth = 1
        highlight.stroke()

        let colored = tint != .normal
        let fg = colored ? UIColor.white : p.keyText
        let shadow = colored ? UIColor(0, 0, 0, 0.45) : p.keyTextShadow
        let offset = colored ? CGSize(width: 0, height: -1) : p.keyTextShadowOffset
        if let s = symbol, let img = Draw.symbol(s, pointSize: symbolSize, weight: .bold, color: fg) {
            Draw.image(img, centeredIn: inner, shadow: shadow, offset: offset)
        } else if let t = title {
            Draw.text(t, font: Fonts.bold(fontSize), color: fg, shadow: shadow, offset: offset, in: inner)
        }
    }
}

/// Croce direzionale circolare con tasto OK centrale.
final class DPadView: ThemedControl {
    var onPress: ((RemoteKey) -> Void)?
    private var pressed: RemoteKey?
    private let repeater = KeyRepeater()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isExclusiveTouch = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    private var center0: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var outerRadius: CGFloat { min(bounds.width, bounds.height) / 2 - 5 }
    private var innerRadius: CGFloat { outerRadius * 0.4 }

    private func key(at point: CGPoint) -> RemoteKey? {
        let dx = point.x - center0.x, dy = point.y - center0.y
        let distance = hypot(dx, dy)
        if distance <= innerRadius { return .ok }
        if distance > outerRadius + 12 { return nil }
        let angle = atan2(dy, dx)
        if angle >= -.pi / 4 && angle < .pi / 4 { return .right }
        if angle >= .pi / 4 && angle < 3 * .pi / 4 { return .down }
        if angle >= -3 * .pi / 4 && angle < -.pi / 4 { return .up }
        return .left
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        hypot(point.x - center0.x, point.y - center0.y) <= outerRadius + 12
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let k = key(at: touch.location(in: self)) else { return false }
        pressed = k
        setNeedsDisplay()
        fire(k)
        if k != .ok { repeater.start { [weak self] in self?.fire(k) } }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        release()
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        release()
        super.cancelTracking(with: event)
    }

    private func release() {
        repeater.stop()
        pressed = nil
        setNeedsDisplay()
    }

    private func fire(_ k: RemoteKey) {
        Feedback.tap()
        onPress?(k)
    }

    private func angle(for k: RemoteKey) -> CGFloat {
        switch k {
        case .right: return 0
        case .down: return .pi / 2
        case .left: return .pi
        default: return -.pi / 2
        }
    }

    private func wedge(_ k: RemoteKey) -> UIBezierPath {
        let mid = angle(for: k)
        let path = UIBezierPath()
        path.addArc(withCenter: center0, radius: outerRadius - 1, startAngle: mid - .pi / 4, endAngle: mid + .pi / 4, clockwise: true)
        path.addArc(withCenter: center0, radius: innerRadius + 4, startAngle: mid + .pi / 4, endAngle: mid - .pi / 4, clockwise: false)
        path.close()
        return path
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let c = center0
        let R = outerRadius
        let ri = innerRadius
        let outerRect = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)
        let ring = UIBezierPath(ovalIn: outerRect)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 6, color: p.keyDropShadow.cgColor)
        p.keyBorder.setFill()
        ring.fill()
        ctx.restoreGState()

        let body = outerRect.insetBy(dx: 1, dy: 1)
        Draw.fillVertical(UIBezierPath(ovalIn: body), body, [p.keyTop, p.keyBottom])

        if let k = pressed, k != .ok {
            Draw.fillVertical(wedge(k), body, [p.keyPressedTop, p.keyPressedBottom])
        }

        ctx.saveGState()
        UIBezierPath(ovalIn: body).addClip()
        let gloss = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.5)
        Draw.fillVertical(UIBezierPath(rect: gloss), gloss,
                          [UIColor(255, 255, 255, p.keyGloss * 0.8), UIColor(255, 255, 255, p.keyGloss * 0.1)])
        ctx.restoreGState()

        // Separatori diagonali incisi
        ctx.setLineWidth(1)
        for i in 0..<4 {
            let a = CGFloat.pi / 4 + CGFloat(i) * .pi / 2
            let from = CGPoint(x: c.x + cos(a) * (ri + 5), y: c.y + sin(a) * (ri + 5))
            let to = CGPoint(x: c.x + cos(a) * (R - 3), y: c.y + sin(a) * (R - 3))
            ctx.setStrokeColor(p.keyBorder.withAlphaComponent(0.45).cgColor)
            ctx.move(to: from); ctx.addLine(to: to); ctx.strokePath()
            ctx.setStrokeColor(UIColor(255, 255, 255, p.isDark ? 0.08 : 0.6).cgColor)
            ctx.move(to: CGPoint(x: from.x, y: from.y + 1)); ctx.addLine(to: CGPoint(x: to.x, y: to.y + 1)); ctx.strokePath()
        }

        // Frecce
        let s = max(5, R * 0.085)
        let dist = (R + ri) / 2 + 2
        for k in [RemoteKey.up, .down, .left, .right] {
            let a = angle(for: k)
            let dir = CGPoint(x: cos(a), y: sin(a))
            let perp = CGPoint(x: -dir.y, y: dir.x)
            let tip = CGPoint(x: c.x + dir.x * (dist + s), y: c.y + dir.y * (dist + s))
            let base = CGPoint(x: c.x + dir.x * (dist - s * 0.5), y: c.y + dir.y * (dist - s * 0.5))
            let tri = UIBezierPath()
            tri.move(to: tip)
            tri.addLine(to: CGPoint(x: base.x + perp.x * s, y: base.y + perp.y * s))
            tri.addLine(to: CGPoint(x: base.x - perp.x * s, y: base.y - perp.y * s))
            tri.close()
            ctx.saveGState()
            ctx.setShadow(offset: p.keyTextShadowOffset, blur: 0, color: p.keyTextShadow.cgColor)
            p.keyText.setFill()
            tri.fill()
            ctx.restoreGState()
        }

        // Scanalatura e tasto OK
        let groove = CGRect(x: c.x - ri - 4, y: c.y - ri - 4, width: (ri + 4) * 2, height: (ri + 4) * 2)
        Draw.fillVertical(UIBezierPath(ovalIn: groove), groove,
                          [p.keyGroove.withAlphaComponent(0.9), p.keyGroove.withAlphaComponent(0.35)])
        let okRect = CGRect(x: c.x - ri, y: c.y - ri, width: ri * 2, height: ri * 2)
        let ok = UIBezierPath(ovalIn: okRect)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: p.keyDropShadow.cgColor)
        p.keyBorder.setFill()
        ok.fill()
        ctx.restoreGState()
        let okBody = okRect.insetBy(dx: 1, dy: 1)
        let okPressed = pressed == .ok
        Draw.fillVertical(UIBezierPath(ovalIn: okBody), okBody,
                          okPressed ? [p.keyPressedTop, p.keyPressedBottom] : [p.keyTop, p.keyBottom])
        if !okPressed {
            ctx.saveGState()
            UIBezierPath(ovalIn: okBody).addClip()
            let g = CGRect(x: okBody.minX, y: okBody.minY, width: okBody.width, height: okBody.height * 0.5)
            Draw.fillVertical(UIBezierPath(rect: g), g,
                              [UIColor(255, 255, 255, p.keyGloss), UIColor(255, 255, 255, p.keyGloss * 0.2)])
            ctx.restoreGState()
        }
        Draw.text("OK", font: Fonts.bold(max(14, ri * 0.42)), color: p.keyText,
                  shadow: p.keyTextShadow, offset: p.keyTextShadowOffset, in: okBody)
    }
}

/// Bilanciere verticale +/− (volume, canali).
final class RockerView: ThemedControl {
    let upKey: RemoteKey
    let downKey: RemoteKey
    let label: String
    var onPress: ((RemoteKey) -> Void)?
    private var pressed: RemoteKey?
    private let repeater = KeyRepeater()

    init(up: RemoteKey, down: RemoteKey, label: String) {
        upKey = up
        downKey = down
        self.label = label
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        isExclusiveTouch = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let k = touch.location(in: self).y < bounds.midY ? upKey : downKey
        pressed = k
        setNeedsDisplay()
        fire(k)
        repeater.start { [weak self] in self?.fire(k) }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        release()
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        release()
        super.cancelTracking(with: event)
    }

    private func release() {
        repeater.stop()
        pressed = nil
        setNeedsDisplay()
    }

    private func fire(_ k: RemoteKey) {
        Feedback.tap()
        onPress?(k)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let p = Theme.palette
        let r = bounds.insetBy(dx: 4, dy: 4).offsetBy(dx: 0, dy: -1)
        let radius = r.width / 2
        let outer = UIBezierPath(roundedRect: r, cornerRadius: radius)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: p.keyDropShadow.cgColor)
        p.keyBorder.setFill()
        outer.fill()
        ctx.restoreGState()

        let inner = r.insetBy(dx: 1, dy: 1)
        let body = UIBezierPath(roundedRect: inner, cornerRadius: radius - 1)
        Draw.fillVertical(body, inner, [p.keyTop, p.keyBottom])

        ctx.saveGState()
        body.addClip()
        if let k = pressed {
            let half = k == upKey
                ? CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: inner.height / 2)
                : CGRect(x: inner.minX, y: inner.midY, width: inner.width, height: inner.height / 2)
            Draw.fillVertical(UIBezierPath(rect: half), half, [p.keyPressedTop, p.keyPressedBottom])
        }
        let gloss = CGRect(x: inner.minX, y: inner.minY, width: inner.width * 0.5, height: inner.height)
        ctx.drawLinearGradient(Draw.gradient([UIColor(255, 255, 255, p.keyGloss * 0.5), UIColor(255, 255, 255, 0)]),
                               start: CGPoint(x: gloss.minX, y: gloss.midY),
                               end: CGPoint(x: gloss.maxX, y: gloss.midY), options: [])
        ctx.restoreGState()

        let hl = UIBezierPath(roundedRect: inner.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius - 1.5)
        UIColor(255, 255, 255, 0.18).setStroke()
        hl.lineWidth = 1
        hl.stroke()

        let quarter = inner.height / 4
        if let plus = Draw.symbol("plus", pointSize: 18, weight: .heavy, color: p.keyText) {
            Draw.image(plus, centeredIn: CGRect(x: inner.minX, y: inner.minY + quarter * 0.4, width: inner.width, height: quarter),
                       shadow: p.keyTextShadow, offset: p.keyTextShadowOffset)
        }
        if let minus = Draw.symbol("minus", pointSize: 18, weight: .heavy, color: p.keyText) {
            Draw.image(minus, centeredIn: CGRect(x: inner.minX, y: inner.maxY - quarter * 1.4, width: inner.width, height: quarter),
                       shadow: p.keyTextShadow, offset: p.keyTextShadowOffset)
        }
        Draw.text(label, font: Fonts.bold(12), color: p.keyText.withAlphaComponent(0.8),
                  shadow: p.keyTextShadow, offset: p.keyTextShadowOffset,
                  in: CGRect(x: inner.minX, y: inner.midY - 10, width: inner.width, height: 20))
    }
}

/// Spia LED di stato della connessione, toccabile per riconnettere.
final class StatusLEDView: ThemedControl {
    enum LED { case off, green, amber, red }

    var led: LED = .off { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    override func sizeThatFits(_ size: CGSize) -> CGSize { CGSize(width: 36, height: 30) }
    override var intrinsicContentSize: CGSize { CGSize(width: 36, height: 30) }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let r: CGFloat = 7
        let socket = CGRect(x: c.x - r - 2, y: c.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2)
        UIColor(255, 255, 255, 0.25).setFill()
        UIBezierPath(ovalIn: socket.offsetBy(dx: 0, dy: 1)).fill()
        UIColor(0, 0, 0, 0.55).setFill()
        UIBezierPath(ovalIn: socket).fill()

        let colors: [UIColor]
        let glow: UIColor?
        switch led {
        case .off: colors = [UIColor(130, 130, 130), UIColor(60, 60, 60)]; glow = nil
        case .green: colors = [UIColor(190, 255, 160), UIColor(46, 196, 40), UIColor(12, 118, 10)]; glow = UIColor(80, 255, 60, 0.9)
        case .amber: colors = [UIColor(255, 236, 160), UIColor(250, 172, 20), UIColor(190, 110, 0)]; glow = UIColor(255, 190, 40, 0.9)
        case .red: colors = [UIColor(255, 170, 160), UIColor(232, 40, 30), UIColor(150, 10, 6)]; glow = UIColor(255, 60, 40, 0.9)
        }
        let ledRect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let path = UIBezierPath(ovalIn: ledRect)
        if let glow = glow {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 7, color: glow.cgColor)
            colors[1].setFill()
            path.fill()
            ctx.restoreGState()
        }
        Draw.fillVertical(path, ledRect, colors)
        let shine = CGRect(x: c.x - r * 0.55, y: c.y - r * 0.85, width: r * 1.1, height: r * 0.8)
        Draw.fillVertical(UIBezierPath(ovalIn: shine), shine, [UIColor(255, 255, 255, 0.85), UIColor(255, 255, 255, 0.05)])
    }
}
