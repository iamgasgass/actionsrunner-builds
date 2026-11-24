import UIKit

/// Icona d'app in stile iOS 6: angoli arrotondati, riflesso lucido e ombra.
final class AppIconView: UIView {
    var image: UIImage? { didSet { setNeedsDisplay() } }
    var placeholderName = "" { didSet { setNeedsDisplay() } }
    var pressed = false { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    private var placeholderColors: [UIColor] {
        let seed = placeholderName.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = CGFloat(seed % 360) / 360
        return [UIColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                UIColor(hue: hue, saturation: 0.85, brightness: 0.62, alpha: 1)]
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let side = min(bounds.width, bounds.height) - 6
        let r = CGRect(x: bounds.midX - side / 2, y: 2, width: side, height: side)
        let radius = side * 0.175
        let path = UIBezierPath(roundedRect: r, cornerRadius: radius)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 3, color: UIColor(0, 0, 0, 0.6).cgColor)
        UIColor.black.setFill()
        path.fill()
        ctx.restoreGState()

        ctx.saveGState()
        path.addClip()
        if let img = image {
            UIColor.white.setFill()
            ctx.fill(r)
            let scale = max(r.width / img.size.width, r.height / img.size.height)
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            img.draw(in: CGRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height))
        } else {
            Draw.fillVertical(path, r, placeholderColors)
            let letter = String(placeholderName.prefix(1)).uppercased()
            Draw.text(letter, font: Fonts.bold(side * 0.48), color: .white, shadow: UIColor(0, 0, 0, 0.4),
                      offset: CGSize(width: 0, height: -1), in: r)
        }
        Draw.glossEllipse(in: r, top: 0.55, bottom: 0.12, heightFactor: 0.52)
        if pressed {
            ctx.setFillColor(UIColor(0, 0, 0, 0.4).cgColor)
            ctx.fill(r)
        }
        ctx.restoreGState()

        let border = UIBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius - 0.5)
        UIColor(0, 0, 0, 0.35).setStroke()
        border.lineWidth = 1
        border.stroke()
    }
}
