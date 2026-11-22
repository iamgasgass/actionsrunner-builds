import UIKit
import MapLibre

/// Freccia bianca dell'utente con croce di mira, in stile "videogioco".
final class UserArrowView: MLNUserLocationAnnotationView {
    private let container = CALayer()
    private let arrowLeft = CAShapeLayer()
    private let arrowRight = CAShapeLayer()
    private let hLine = CAGradientLayer()
    private let vLine = CAGradientLayer()
    private var configured = false
    /// colore della freccia per il tema attivo
    static var tint: UIColor = .white
    /// tipo di indicatore per il tema attivo (0 freccia, 1 ingranaggio, 2 anello)
    static var marker: Int = 0
    /// avatar di guida: 0 = Default (freccia del tema), 1 = Alternative (disco blu con freccia bianca)
    static var avatar: Int = 0
    /// indicatore effettivo: 4 = Alternative, 5 = Alternative a blocchi (Pixel Land)
    static var effectiveMarker: Int {
        guard avatar == 1 else { return marker }
        return marker == 3 ? 5 : 4
    }
    private var appliedTint: UIColor?
    private var appliedMarker: Int = -1
    private let markerLayer = CALayer()
    /// cono della bussola (come il "fascio" di Google Maps: più largo quando la bussola è imprecisa)
    private let beam = CAGradientLayer()
    private let beamMask = CAShapeLayer()
    /// cerchio di precisione (visibile quando la posizione è approssimativa)
    private let accuracyRing = CAShapeLayer()
    private var displayedAngle: CGFloat = 0
    private var lastHeading: Double = 0
    private var lastMapDirection: Double = .nan

    override func update() {
        if !configured { configure() }
        if appliedMarker != UserArrowView.effectiveMarker {
            appliedMarker = UserArrowView.effectiveMarker
            let arrow = appliedMarker == 0
            arrowLeft.isHidden = !arrow
            arrowRight.isHidden = !arrow
            hLine.isHidden = !arrow
            vLine.isHidden = !arrow
            markerLayer.isHidden = arrow
            let img = UserArrowView.markerImage(appliedMarker)
            markerLayer.contents = img?.cgImage
            markerLayer.contentsScale = img?.scale ?? 2
            // la freccia pixel ruota con la direzione come quella normale; nessuna sfumatura sui pixel
            switch appliedMarker {
            case 3: markerLayer.frame = CGRect(x: 6, y: 6, width: 32, height: 32)
            case 4: markerLayer.frame = container.bounds.insetBy(dx: -8, dy: -8)
            case 5: markerLayer.frame = CGRect(x: 2, y: 2, width: 40, height: 40)
            default: markerLayer.frame = container.bounds.insetBy(dx: -14, dy: -14)
            }
        }
        if appliedTint != UserArrowView.tint {
            appliedTint = UserArrowView.tint
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UserArrowView.tint.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
            arrowLeft.fillColor = UserArrowView.tint.cgColor
            arrowRight.fillColor = UIColor(hue: h, saturation: sat, brightness: b * 0.78, alpha: a).cgColor
        }
        guard let map = mapView else { return }

        // Come Google Maps: in movimento la freccia segue la direzione di marcia,
        // da fermi segue la bussola del telefono (nord vero, altrimenti magnetico).
        let loc = userLocation?.location
        var heading: Double?
        var compass = false
        var compassAccuracy: Double = 25
        if let l = loc, l.speed >= 1.5, l.course >= 0 {
            heading = l.course
        } else if let h = userLocation?.heading {
            let v = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
            if v >= 0 {
                heading = v
                compass = true
                if h.headingAccuracy > 0 { compassAccuracy = h.headingAccuracy }
            }
        }
        if heading == nil, let c = loc?.course, c >= 0 { heading = c }
        if let h = heading { lastHeading = h }

        // rotazione dolce sul percorso più breve (niente giro completo passando da 359° a 0°);
        // se a ruotare è la mappa (gesto dell'utente) la freccia la segue senza ritardo
        let target = CGFloat((lastHeading - map.direction) * .pi / 180)
        var delta = target - displayedAngle
        delta = atan2(sin(delta), cos(delta))
        displayedAngle += delta
        let mapRotating = !lastMapDirection.isNaN && abs(map.direction - lastMapDirection) > 0.01
        lastMapDirection = map.direction
        let pitch = CGFloat(map.camera.pitch * .pi / 180)

        var t = CATransform3DIdentity
        t.m34 = -1.0 / 400
        t = CATransform3DRotate(t, pitch * 0.85, 1, 0, 0)
        t = CATransform3DRotate(t, displayedAngle, 0, 0, 1)

        // larghezza del cono = precisione della bussola (15°–70°)
        let half = CGFloat(min(70, max(15, compassAccuracy))) * .pi / 180
        let wedge = UIBezierPath()
        wedge.move(to: CGPoint(x: 64, y: 64))
        wedge.addArc(withCenter: CGPoint(x: 64, y: 64), radius: 64,
                     startAngle: -.pi / 2 - half, endAngle: -.pi / 2 + half, clockwise: true)
        wedge.close()

        // cerchio di precisione in punti dello schermo
        var ringRadius: CGFloat = 0
        if let l = loc, l.horizontalAccuracy > 0 {
            let mpp = map.metersPerPoint(atLatitude: l.coordinate.latitude)
            if mpp > 0 { ringRadius = CGFloat(l.horizontalAccuracy / mpp) }
        }

        CATransaction.begin()
        if mapRotating || abs(delta) < 0.002 {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        }
        container.transform = t
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        beam.isHidden = !compass || appliedMarker != 0
        beamMask.path = wedge.cgPath
        let tintCG = UserArrowView.tint
        beam.colors = [tintCG.withAlphaComponent(0.45).cgColor, tintCG.withAlphaComponent(0).cgColor]
        let showRing = ringRadius > 26
        accuracyRing.isHidden = !showRing
        if showRing {
            let r = min(ringRadius, 600)
            accuracyRing.path = UIBezierPath(ovalIn: CGRect(x: 22 - r, y: 22 - r, width: r * 2, height: r * 2)).cgPath
            accuracyRing.fillColor = tintCG.withAlphaComponent(0.12).cgColor
            accuracyRing.strokeColor = tintCG.withAlphaComponent(0.35).cgColor
        }
        CATransaction.commit()
    }

    private func configure() {
        configured = true
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        clipsToBounds = false
        backgroundColor = .clear

        // croce di mira (in coordinate schermo)
        let lineColor = UIColor.white.withAlphaComponent(0.55).cgColor
        let clear = UIColor.white.withAlphaComponent(0).cgColor
        hLine.colors = [clear, lineColor, lineColor, clear]
        hLine.locations = [0, 0.3, 0.7, 1]
        hLine.startPoint = CGPoint(x: 0, y: 0.5)
        hLine.endPoint = CGPoint(x: 1, y: 0.5)
        hLine.frame = CGRect(x: 22 - 700, y: 21.5, width: 1400, height: 1)
        layer.addSublayer(hLine)

        vLine.colors = [clear, lineColor, lineColor, clear]
        vLine.locations = [0, 0.25, 0.75, 1]
        vLine.startPoint = CGPoint(x: 0.5, y: 0)
        vLine.endPoint = CGPoint(x: 0.5, y: 1)
        vLine.frame = CGRect(x: 21.5, y: 22 - 150, width: 1, height: 450)
        layer.addSublayer(vLine)

        accuracyRing.lineWidth = 1
        accuracyRing.isHidden = true
        layer.insertSublayer(accuracyRing, at: 0)

        container.frame = bounds
        layer.addSublayer(container)

        // cono della bussola: parte dal centro e si apre davanti alla freccia
        beam.frame = CGRect(x: 22 - 64, y: 22 - 64, width: 128, height: 64)
        beam.startPoint = CGPoint(x: 0.5, y: 1)
        beam.endPoint = CGPoint(x: 0.5, y: 0)
        beam.mask = beamMask
        beam.isHidden = true
        container.addSublayer(beam)
        markerLayer.frame = bounds.insetBy(dx: -14, dy: -14)
        markerLayer.contentsGravity = .resizeAspect
        markerLayer.magnificationFilter = .nearest
        markerLayer.minificationFilter = .nearest
        markerLayer.isHidden = true
        container.addSublayer(markerLayer)

        let w: CGFloat = 44
        let left = UIBezierPath()
        left.move(to: CGPoint(x: w / 2, y: 3))
        left.addLine(to: CGPoint(x: 8, y: 40))
        left.addLine(to: CGPoint(x: w / 2, y: 31))
        left.close()
        let right = UIBezierPath()
        right.move(to: CGPoint(x: w / 2, y: 3))
        right.addLine(to: CGPoint(x: w - 8, y: 40))
        right.addLine(to: CGPoint(x: w / 2, y: 31))
        right.close()

        arrowLeft.path = left.cgPath
        arrowLeft.fillColor = UIColor.white.cgColor
        arrowRight.path = right.cgPath
        arrowRight.fillColor = UIColor(white: 0.78, alpha: 1).cgColor
        for l in [arrowLeft, arrowRight] {
            l.frame = container.bounds
            l.shadowColor = UIColor.black.cgColor
            l.shadowOpacity = 0.6
            l.shadowRadius = 4
            l.shadowOffset = CGSize(width: 0, height: 2)
            container.addSublayer(l)
        }
    }
}

extension UserArrowView {
    /// Avatar "Alternative": disco blu appoggiato sulla mappa con freccia bianca (lato destro azzurrino)
    static func discAvatar() -> UIImage {
        let s: CGFloat = 60
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            let c = ctx.cgContext
            let disc = CGRect(x: 3, y: 3, width: s - 6, height: s - 6)
            c.setShadow(offset: CGSize(width: 0, height: 2), blur: 5, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            c.setFillColor(UIColor(hex: 0x3B78F2).cgColor)
            c.fillEllipse(in: disc)
            c.setShadow(offset: .zero, blur: 0, color: nil)
            c.setStrokeColor(UIColor(hex: 0x2A5FD0).cgColor)
            c.setLineWidth(1.5)
            c.strokeEllipse(in: disc.insetBy(dx: 0.75, dy: 0.75))
            let top = CGPoint(x: s / 2, y: 15), notch = CGPoint(x: s / 2, y: 36)
            let left = UIBezierPath()
            left.move(to: top); left.addLine(to: CGPoint(x: 17, y: 42)); left.addLine(to: notch); left.close()
            let right = UIBezierPath()
            right.move(to: top); right.addLine(to: CGPoint(x: s - 17, y: 42)); right.addLine(to: notch); right.close()
            c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.3).cgColor)
            UIColor.white.setFill(); left.fill()
            UIColor(hex: 0xD3E4FF).setFill(); right.fill()
        }
    }

    /// Avatar "Alternative" a blocchi per Pixel Land: disco blu pixelato con freccia bianca a pixel
    static func pixelDiscAvatar() -> UIImage {
        let rows = [
            "......KKKKKKKK......",
            "....KKBBBBBBBBKK....",
            "...KBBBBBBBBBBBBK...",
            "..KBBBBBBWwBBBBBBK..",
            ".KBBBBBBBWwBBBBBBBK.",
            ".KBBBBBBWWwwBBBBBBK.",
            "KBBBBBBBWWwwBBBBBBBK",
            "KBBBBBBWWWwwwBBBBBBK",
            "KBBBBBBWWWwwwBBBBBBK",
            "KBBBBBWWWWwwwwBBBBBK",
            "KBBBBBWWWBBwwwBBBBBK",
            "KBBBBWWWBBBBwwwBBBBK",
            "KBBBBWWBBBBBBwwBBBBK",
            "KBBBBBBBBBBBBBBBBBBK",
            ".KBBBBBBBBBBBBBBBBK.",
            ".KBBBBBBBBBBBBBBBBK.",
            "..KBBBBBBBBBBBBBBK..",
            "...KBBBBBBBBBBBBK...",
            "....KKBBBBBBBBKK....",
            "......KKKKKKKK......"
        ]
        let colors: [Character: UIColor] = ["K": UIColor(hex: 0x1C3F8F), "B": UIColor(hex: 0x3B78F2),
                                            "W": UIColor(hex: 0xF8F8F8), "w": UIColor(hex: 0xC9DCFF)]
        let px: CGFloat = 2
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 20 * px, height: 20 * px), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.setShouldAntialias(false)
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let col = colors[ch] else { continue }
                    c.setFillColor(col.cgColor)
                    c.fill(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px))
                }
            }
        }
    }

    /// Freccia del giocatore in stile mappa a blocchi: punta bianca pixelata con lato in ombra e contorno scuro.
    static func pixelArrow() -> UIImage {
        let rows = [
            ".......KK.......",
            "......KWwK......",
            "......KWwK......",
            ".....KWWwwK.....",
            ".....KWWwwK.....",
            "....KWWWwwwK....",
            "....KWWWwwwK....",
            "...KWWWWwwwwK...",
            "...KWWWWwwwwK...",
            "..KWWWWKKwwwwK..",
            "..KWWWK..KwwwK..",
            ".KWWWK....KwwwK.",
            ".KWWK......KwwK.",
            "KWWK........KwwK",
            "KKK..........KKK",
            "................"
        ]
        let colors: [Character: UIColor] = ["K": UIColor(hex: 0x1E1E1E), "W": UIColor(hex: 0xF8F8F8),
                                            "w": UIColor(hex: 0xC6C6C6)]
        let px: CGFloat = 2
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: 16 * px, height: 16 * px), format: fmt).image { ctx in
            let c = ctx.cgContext
            c.setShouldAntialias(false)
            // ombra a blocchi sotto la freccia
            c.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch != "." {
                    c.fill(CGRect(x: CGFloat(x) * px + px * 0.67, y: CGFloat(y) * px + px, width: px, height: px))
                }
            }
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let col = colors[ch] else { continue }
                    c.setFillColor(col.cgColor)
                    c.fill(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * px, width: px, height: px))
                }
            }
        }
    }

    /// 1 = ingranaggio (Street Heat), 2 = anello-bussola marrone (Old Kingdom)
    /// La freccia standard esattamente come sulla mappa (stessa forma, colori e ombra), per le anteprime
    static func defaultArrowImage(tint: UIColor) -> UIImage {
        let w: CGFloat = 44
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: w), format: fmt).image { ctx in
            let c = ctx.cgContext
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            tint.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
            let left = UIBezierPath()
            left.move(to: CGPoint(x: w / 2, y: 3)); left.addLine(to: CGPoint(x: 8, y: 40)); left.addLine(to: CGPoint(x: w / 2, y: 31)); left.close()
            let right = UIBezierPath()
            right.move(to: CGPoint(x: w / 2, y: 3)); right.addLine(to: CGPoint(x: w - 8, y: 40)); right.addLine(to: CGPoint(x: w / 2, y: 31)); right.close()
            c.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            tint.setFill(); left.fill()
            UIColor(hue: h, saturation: sat, brightness: b * 0.78, alpha: a).setFill(); right.fill()
        }
    }

    static func markerImage(_ kind: Int) -> UIImage? {
        if kind == 3 { return pixelArrow() }
        if kind == 4 { return discAvatar() }
        if kind == 5 { return pixelDiscAvatar() }
        let size = CGSize(width: 72, height: 72)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            let c = ctx.cgContext
            if kind == 1 {
                let cfg = UIImage.SymbolConfiguration(pointSize: 54, weight: .regular)
                if let gear = UIImage(systemName: "gearshape", withConfiguration: cfg) {
                    let r = CGRect(x: (72 - gear.size.width) / 2, y: (72 - gear.size.height) / 2,
                                   width: gear.size.width, height: gear.size.height)
                    c.setShadow(offset: .zero, blur: 3, color: UIColor.black.withAlphaComponent(0.4).cgColor)
                    gear.withTintColor(UIColor.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal).draw(in: r)
                }
            } else {
                let brown = UIColor(hex: 0x4A2C1A)
                let center = CGPoint(x: 36, y: 36)
                c.setStrokeColor(brown.cgColor)
                c.setLineWidth(5)
                c.strokeEllipse(in: CGRect(x: 14, y: 14, width: 44, height: 44))
                c.setStrokeColor(UIColor(hex: 0xC9A27A).cgColor)
                c.setLineWidth(1.2)
                c.strokeEllipse(in: CGRect(x: 17.5, y: 17.5, width: 37, height: 37))
                c.setFillColor(brown.cgColor)
                for i in 0..<8 {
                    let a = CGFloat(i) * .pi / 4
                    let long: CGFloat = i % 2 == 0 ? 33 : 28
                    let tip = CGPoint(x: center.x + cos(a) * long, y: center.y + sin(a) * long)
                    let l = CGPoint(x: center.x + cos(a - 0.12) * 21, y: center.y + sin(a - 0.12) * 21)
                    let r = CGPoint(x: center.x + cos(a + 0.12) * 21, y: center.y + sin(a + 0.12) * 21)
                    c.move(to: l); c.addLine(to: tip); c.addLine(to: r); c.closePath()
                }
                c.fillPath()
            }
        }
    }
}

/// Fumetto bianco con quadrifoglio e nome del luogo.
final class PinBubbleView: MLNAnnotationView {
    private let bubble = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let tail = CAShapeLayer()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        scalesWithViewingDistance = false
        bubble.backgroundColor = .white
        bubble.layer.cornerRadius = 14
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.35
        bubble.layer.shadowRadius = 8
        bubble.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(bubble)
        bubble.addSubview(icon)
        label.font = .systemFont(ofSize: 16, weight: .bold)
        label.textColor = .black
        bubble.addSubview(label)
        tail.fillColor = UIColor.white.cgColor
        layer.insertSublayer(tail, at: 0)
    }

    func configure(title: String, theme: MapTheme) {
        icon.image = DestinationMarker.image(for: theme, size: 30)
        icon.layer.magnificationFilter = theme.id == "pixel" ? .nearest : .linear
        label.text = title
        let hasTitle = !title.isEmpty
        let height: CGFloat = 50
        let textWidth = hasTitle ? min(220, label.intrinsicContentSize.width) : 0
        let width: CGFloat = hasTitle ? 14 + 30 + 8 + textWidth + 16 : height
        let tailH: CGFloat = 10
        frame = CGRect(x: 0, y: 0, width: width, height: height + tailH)
        bubble.frame = CGRect(x: 0, y: 0, width: width, height: height)
        icon.frame = hasTitle ? CGRect(x: 14, y: 10, width: 30, height: 30) : CGRect(x: 10, y: 10, width: 30, height: 30)
        label.frame = CGRect(x: 52, y: 0, width: textWidth, height: height)
        label.isHidden = !hasTitle

        let p = UIBezierPath()
        p.move(to: CGPoint(x: width / 2 - 9, y: height - 1))
        p.addLine(to: CGPoint(x: width / 2, y: height + tailH))
        p.addLine(to: CGPoint(x: width / 2 + 9, y: height - 1))
        p.close()
        tail.path = p.cgPath
        centerOffset = CGVector(dx: 0, dy: -(height + tailH) / 2)
    }
}

/// Segnaposto dei risultati di ricerca (a goccia, colore del tema) — tocca per aprire la scheda del luogo.
final class ResultMarkerView: MLNAnnotationView {
    private let imageView = UIImageView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 30, height: 40)
        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        centerOffset = CGVector(dx: 0, dy: -20)
        scalesWithViewingDistance = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func configure(color: UIColor) {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        imageView.image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40), format: fmt).image { ctx in
            let c = ctx.cgContext
            let r: CGFloat = 13
            let center = CGPoint(x: 15, y: 15)
            let path = UIBezierPath()
            path.addArc(withCenter: center, radius: r, startAngle: .pi * 0.78, endAngle: .pi * 0.22, clockwise: true)
            path.addLine(to: CGPoint(x: 15, y: 38))
            path.close()
            c.setShadow(offset: CGSize(width: 0, height: 2), blur: 4, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            color.setFill(); path.fill()
            c.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.white.withAlphaComponent(0.9).setStroke(); path.lineWidth = 1.5; path.stroke()
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: 10, y: 10, width: 10, height: 10)).fill()
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        UIView.animate(withDuration: 0.15) {
            self.transform = selected ? CGAffineTransform(scaleX: 1.25, y: 1.25) : .identity
        }
    }
}


/// Fumetto sopra un percorso alternativo: bordo e testo nel colore del percorso, fondo scuro
final class AltLabelView: MLNAnnotationView {
    private let label = UILabel()
    private let bubble = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        scalesWithViewingDistance = false
        bubble.layer.cornerRadius = 10
        bubble.layer.borderWidth = 2
        bubble.layer.shadowColor = UIColor.black.cgColor
        bubble.layer.shadowOpacity = 0.4
        bubble.layer.shadowRadius = 4
        bubble.layer.shadowOffset = CGSize(width: 0, height: 2)
        addSubview(bubble)
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textAlignment = .center
        bubble.addSubview(label)
    }

    func configure(text: String, color: UIColor) {
        label.text = text
        label.textColor = .white
        bubble.backgroundColor = UIColor(hex: 0x10162A).withAlphaComponent(0.92)
        bubble.layer.borderColor = color.cgColor
        let w = label.intrinsicContentSize.width + 22
        frame = CGRect(x: 0, y: 0, width: w, height: 32)
        bubble.frame = bounds
        label.frame = bounds
        centerOffset = CGVector(dx: w / 2 - 6, dy: -18)
    }
}
