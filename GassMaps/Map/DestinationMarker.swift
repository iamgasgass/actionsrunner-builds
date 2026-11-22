import UIKit
import SwiftUI

/// Indicatore di destinazione (segnaposto del luogo fissato), con una forma diversa per ogni tema,
/// disegnata dall'app nello stile del gioco a cui il tema si ispira.
enum DestinationMarker {
    private static var cache: [String: UIImage] = [:]
    private static let lock = NSLock()

    @MainActor
    static func image(for theme: MapTheme, size: CGFloat) -> UIImage {
        return drawnImage(for: theme, size: size)
    }

    private static func drawnImage(for theme: MapTheme, size: CGFloat) -> UIImage {
        let key = "\(theme.id)|\(Int(size * 10))"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let img = draw(theme, size: size)
        cache[key] = img
        return img
    }

    private static func draw(_ theme: MapTheme, size s: CGFloat) -> UIImage {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s), format: fmt).image { ctx in
            let c = ctx.cgContext
            switch theme.id {
            case "noir": cloverInk(c, s, color: theme.accent)
            case "palm": compassStar(c, s)
            case "dust": sketchCircleX(c, s)
            case "canyon": checkeredFlags(c, s)
            case "bunker": terminalDiamond(c, s)
            case "pixel": pixelX(c, s)
            case "neon": neonDiamond(c, s)
            case "kingdom": heraldicShield(c, s)
            case "contract": tacticalPin(c, s)
            case "storm": balloonPin(c, s, color: theme.accent)
            case "midnight": balloonPin(c, s, color: theme.accent)   // palloncino di Storm Isle nel ciano del percorso   // stesso colore del percorso
            case "crimson": pinkStar(c, s)
            default: cloverClassic(c, s, color: theme.accent)   // Street Heat: invariato
            }
        }
    }

    // MARK: Vice Noir — quadrifoglio viola con bordi e pallino centrale neri

    private static func cloverPetals(_ s: CGFloat) -> [CGPoint] {
        let petal = s * 0.36, mid = s / 2
        return [CGPoint(x: mid, y: mid - petal * 0.62), CGPoint(x: mid, y: mid + petal * 0.62),
                CGPoint(x: mid - petal * 0.62, y: mid), CGPoint(x: mid + petal * 0.62, y: mid)]
    }

    private static func cloverInk(_ c: CGContext, _ s: CGFloat, color: UIColor) {
        let petal = s * 0.36, mid = s / 2, b = max(1.5, s * 0.06)
        c.setFillColor(UIColor.black.cgColor)
        for p in cloverPetals(s) {
            c.fillEllipse(in: CGRect(x: p.x - petal / 2 - b, y: p.y - petal / 2 - b, width: petal + b * 2, height: petal + b * 2))
        }
        c.setFillColor(color.cgColor)
        for p in cloverPetals(s) {
            c.fillEllipse(in: CGRect(x: p.x - petal / 2, y: p.y - petal / 2, width: petal, height: petal))
        }
        c.fillEllipse(in: CGRect(x: mid - petal * 0.55, y: mid - petal * 0.55, width: petal * 1.1, height: petal * 1.1))
        c.setFillColor(UIColor.black.cgColor)
        c.fillEllipse(in: CGRect(x: mid - petal * 0.22, y: mid - petal * 0.22, width: petal * 0.44, height: petal * 0.44))
    }

    private static func cloverClassic(_ c: CGContext, _ s: CGFloat, color: UIColor) {
        let petal = s * 0.36, mid = s / 2
        c.setFillColor(UIColor.white.cgColor)
        for p in cloverPetals(s) {
            c.fillEllipse(in: CGRect(x: p.x - petal / 2 - 2, y: p.y - petal / 2 - 2, width: petal + 4, height: petal + 4))
        }
        c.setFillColor(color.cgColor)
        for p in cloverPetals(s) {
            c.fillEllipse(in: CGRect(x: p.x - petal / 2, y: p.y - petal / 2, width: petal, height: petal))
        }
        c.fillEllipse(in: CGRect(x: mid - petal * 0.55, y: mid - petal * 0.55, width: petal * 1.1, height: petal * 1.1))
        c.setFillColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        c.fillEllipse(in: CGRect(x: mid - petal * 0.2, y: mid - petal * 0.2, width: petal * 0.4, height: petal * 0.4))
    }

    // MARK: Palm Coast — disco nero, stella rossa a quattro punte, centro nero con anello rosso (come la foto)

    private static func compassStar(_ c: CGContext, _ s: CGFloat) {
        let m = s / 2
        let r = s * 0.48
        // disco nero con bordo grigio scuro
        c.setFillColor(UIColor(hex: 0x0B0B0B).cgColor)
        c.fillEllipse(in: CGRect(x: m - r, y: m - r, width: r * 2, height: r * 2))
        c.setStrokeColor(UIColor(hex: 0x3A3A3A).cgColor)
        c.setLineWidth(s * 0.035)
        c.strokeEllipse(in: CGRect(x: m - r, y: m - r, width: r * 2, height: r * 2).insetBy(dx: s * 0.02, dy: s * 0.02))
        // stella a quattro punte con lati concavi
        let tip = s * 0.39, waist = s * 0.12
        let star = UIBezierPath()
        for i in 0..<4 {
            let a = CGFloat(i) * .pi / 2 - .pi / 2
            let pt = CGPoint(x: m + cos(a) * tip, y: m + sin(a) * tip)
            let na = a + .pi / 2
            let next = CGPoint(x: m + cos(na) * tip, y: m + sin(na) * tip)
            let ctrl = CGPoint(x: m + cos(a + .pi / 4) * waist, y: m + sin(a + .pi / 4) * waist)
            if i == 0 { star.move(to: pt) }
            star.addQuadCurve(to: next, controlPoint: ctrl)
        }
        star.close()
        c.setFillColor(UIColor(hex: 0xA3262C).cgColor)
        c.addPath(star.cgPath); c.fillPath()
        // centro: anello rosso e foro nero
        let ring = s * 0.15
        c.setFillColor(UIColor(hex: 0xA3262C).cgColor)
        c.fillEllipse(in: CGRect(x: m - ring, y: m - ring, width: ring * 2, height: ring * 2))
        let hole = s * 0.1
        c.setFillColor(UIColor(hex: 0x0B0B0B).cgColor)
        c.fillEllipse(in: CGRect(x: m - hole, y: m - hole, width: hole * 2, height: hole * 2))
    }

    // MARK: Dust Valley — "X" rossa da mappa del tesoro su pergamena, inchiostro scuro

    private static func treasureX(_ c: CGContext, _ s: CGFloat) {
        let m = s / 2, r = s * 0.46
        let diamond = UIBezierPath()
        diamond.move(to: CGPoint(x: m, y: m - r)); diamond.addLine(to: CGPoint(x: m + r, y: m))
        diamond.addLine(to: CGPoint(x: m, y: m + r)); diamond.addLine(to: CGPoint(x: m - r, y: m)); diamond.close()
        c.setFillColor(UIColor(hex: 0xE6D3AA).cgColor)
        c.addPath(diamond.cgPath); c.fillPath()
        c.setStrokeColor(UIColor(hex: 0x2B1B0B).cgColor)
        c.setLineWidth(s * 0.06); c.setLineJoin(.round)
        c.addPath(diamond.cgPath); c.strokePath()
        let k = s * 0.17
        c.setLineCap(.round)
        c.setLineWidth(s * 0.12)
        c.setStrokeColor(UIColor(hex: 0x2B1B0B).cgColor)
        c.move(to: CGPoint(x: m - k, y: m - k)); c.addLine(to: CGPoint(x: m + k, y: m + k))
        c.move(to: CGPoint(x: m + k, y: m - k)); c.addLine(to: CGPoint(x: m - k, y: m + k))
        c.strokePath()
        c.setLineWidth(s * 0.07)
        c.setStrokeColor(UIColor(hex: 0xB0201E).cgColor)
        c.move(to: CGPoint(x: m - k, y: m - k)); c.addLine(to: CGPoint(x: m + k, y: m + k))
        c.move(to: CGPoint(x: m + k, y: m - k)); c.addLine(to: CGPoint(x: m - k, y: m + k))
        c.strokePath()
    }

    // MARK: Bunker OS — rombo verde da terminale con alone e punto pieno

    private static func terminalDiamond(_ c: CGContext, _ s: CGFloat) {
        let m = s / 2, r = s * 0.4
        let green = UIColor(hex: 0x5DFF5D)
        let d = UIBezierPath()
        d.move(to: CGPoint(x: m, y: m - r)); d.addLine(to: CGPoint(x: m + r, y: m))
        d.addLine(to: CGPoint(x: m, y: m + r)); d.addLine(to: CGPoint(x: m - r, y: m)); d.close()
        c.setShadow(offset: .zero, blur: s * 0.12, color: green.withAlphaComponent(0.9).cgColor)
        c.setFillColor(UIColor(hex: 0x031203).cgColor)
        c.addPath(d.cgPath); c.fillPath()
        c.setStrokeColor(green.cgColor); c.setLineWidth(s * 0.07)
        c.addPath(d.cgPath); c.strokePath()
        c.setFillColor(green.cgColor)
        let i = s * 0.13
        let inner = UIBezierPath()
        inner.move(to: CGPoint(x: m, y: m - i)); inner.addLine(to: CGPoint(x: m + i, y: m))
        inner.addLine(to: CGPoint(x: m, y: m + i)); inner.addLine(to: CGPoint(x: m - i, y: m)); inner.close()
        c.addPath(inner.cgPath); c.fillPath()
    }

    // MARK: Pixel Land — "X" rossa pixelata da mappa del tesoro

    private static func pixelX(_ c: CGContext, _ s: CGFloat) {
        let rows = [
            "KKK......KKK",
            "KrrK....KrrK",
            "KrRrK..KrRrK",
            ".KrRrKKrRrK.",
            "..KrRrrRrK..",
            "...KrRRrK...",
            "...KrRRrK...",
            "..KrRrrRrK..",
            ".KrRrKKrRrK.",
            "KrRrK..KrRrK",
            "KrrK....KrrK",
            "KKK......KKK"
        ]
        let colors: [Character: UIColor] = ["K": UIColor(hex: 0x2A0A0A), "r": UIColor(hex: 0xE03030),
                                            "R": UIColor(hex: 0x9A1414)]
        let px = floor(s / 12 * 2) / 2
        let o = (s - px * 12) / 2
        c.setShouldAntialias(false)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                guard let col = colors[ch] else { continue }
                c.setFillColor(col.cgColor)
                c.fill(CGRect(x: o + CGFloat(x) * px, y: o + CGFloat(y) * px, width: px, height: px))
            }
        }
    }

    // MARK: Neon District — rombo neon giallo con chevron, alone

    private static func neonDiamond(_ c: CGContext, _ s: CGFloat) {
        let m = s / 2, r = s * 0.4
        let yellow = UIColor(hex: 0xF5E33A)
        let d = UIBezierPath()
        d.move(to: CGPoint(x: m, y: m - r)); d.addLine(to: CGPoint(x: m + r, y: m))
        d.addLine(to: CGPoint(x: m, y: m + r)); d.addLine(to: CGPoint(x: m - r, y: m)); d.close()
        c.setShadow(offset: .zero, blur: s * 0.14, color: yellow.withAlphaComponent(0.8).cgColor)
        c.setFillColor(UIColor(hex: 0x0A0A0A).withAlphaComponent(0.85).cgColor)
        c.addPath(d.cgPath); c.fillPath()
        c.setStrokeColor(yellow.cgColor); c.setLineWidth(s * 0.06)
        c.addPath(d.cgPath); c.strokePath()
        // chevron verso il basso
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setLineWidth(s * 0.075); c.setLineCap(.square); c.setLineJoin(.miter)
        c.move(to: CGPoint(x: m - s * 0.14, y: m - s * 0.06))
        c.addLine(to: CGPoint(x: m, y: m + s * 0.08))
        c.addLine(to: CGPoint(x: m + s * 0.14, y: m - s * 0.06))
        c.strokePath()
    }

    // MARK: Old Kingdom — scudo araldico rosso scuro con bordo d'oro e giglio stilizzato

    private static func heraldicShield(_ c: CGContext, _ s: CGFloat) {
        let w = s * 0.74, h = s * 0.88
        let x = (s - w) / 2, y = (s - h) / 2
        let shield = UIBezierPath()
        shield.move(to: CGPoint(x: x, y: y))
        shield.addLine(to: CGPoint(x: x + w, y: y))
        shield.addLine(to: CGPoint(x: x + w, y: y + h * 0.45))
        shield.addQuadCurve(to: CGPoint(x: x + w / 2, y: y + h), controlPoint: CGPoint(x: x + w, y: y + h * 0.85))
        shield.addQuadCurve(to: CGPoint(x: x, y: y + h * 0.45), controlPoint: CGPoint(x: x, y: y + h * 0.85))
        shield.close()
        c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        c.setFillColor(UIColor(hex: 0x7A1E1A).cgColor)
        c.addPath(shield.cgPath); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setStrokeColor(UIColor(hex: 0xD9B45A).cgColor); c.setLineWidth(s * 0.06)
        c.addPath(shield.cgPath); c.strokePath()
        // giglio stilizzato
        let m = s / 2, gy = y + h * 0.48
        c.setFillColor(UIColor(hex: 0xE8C76A).cgColor)
        let petal = UIBezierPath()
        petal.move(to: CGPoint(x: m, y: gy - s * 0.24))
        petal.addQuadCurve(to: CGPoint(x: m, y: gy + s * 0.08), controlPoint: CGPoint(x: m + s * 0.11, y: gy - s * 0.06))
        petal.addQuadCurve(to: CGPoint(x: m, y: gy - s * 0.24), controlPoint: CGPoint(x: m - s * 0.11, y: gy - s * 0.06))
        c.addPath(petal.cgPath); c.fillPath()
        for side: CGFloat in [-1, 1] {
            let p = UIBezierPath()
            p.move(to: CGPoint(x: m + side * s * 0.03, y: gy + s * 0.02))
            p.addQuadCurve(to: CGPoint(x: m + side * s * 0.2, y: gy - s * 0.1), controlPoint: CGPoint(x: m + side * s * 0.2, y: gy + s * 0.06))
            p.addQuadCurve(to: CGPoint(x: m + side * s * 0.03, y: gy - s * 0.02), controlPoint: CGPoint(x: m + side * s * 0.1, y: gy - s * 0.04))
            p.close()
            c.addPath(p.cgPath); c.fillPath()
        }
        c.fill(CGRect(x: m - s * 0.13, y: gy + s * 0.07, width: s * 0.26, height: s * 0.045))
    }

    // MARK: Silent Contract — quadrato interamente nero con segnaposto rosso

    private static func tacticalPin(_ c: CGContext, _ s: CGFloat) {
        let r = CGRect(x: s * 0.08, y: s * 0.08, width: s * 0.84, height: s * 0.84)
        c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.45).cgColor)
        c.setFillColor(UIColor(hex: 0x111111).cgColor)
        c.addPath(UIBezierPath(roundedRect: r, cornerRadius: s * 0.06).cgPath); c.fillPath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        let cfg = UIImage.SymbolConfiguration(pointSize: s * 0.52, weight: .bold)
        if let pin = UIImage(systemName: "mappin", withConfiguration: cfg)?
            .withTintColor(UIColor(hex: 0xD8333A), renderingMode: .alwaysOriginal) {
            let k = min(r.width * 0.62 / pin.size.width, r.height * 0.7 / pin.size.height)
            let sz = CGSize(width: pin.size.width * k, height: pin.size.height * k)
            pin.draw(in: CGRect(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
        }
    }

    // MARK: Dust Valley — cerchio rosso con X, tratto a mano con contorno nero

    private static func sketchCircleX(_ c: CGContext, _ s: CGFloat) {
        let m = s / 2
        let r = s * 0.34
        let red = UIColor(hex: 0xD8262B)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        // anello leggermente irregolare (due passate come uno schizzo)
        func ring(_ dr: CGFloat, _ rot: CGFloat) -> UIBezierPath {
            let p = UIBezierPath()
            for i in 0...36 {
                let a = CGFloat(i) / 36 * 2 * .pi + rot
                let wobble = 1 + 0.035 * sin(a * 3 + rot * 5)
                let pt = CGPoint(x: m + cos(a) * (r + dr) * wobble, y: m + sin(a) * (r + dr) * wobble * 0.97)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            return p
        }
        let x1 = UIBezierPath()
        x1.move(to: CGPoint(x: m - r * 0.95, y: m - r * 1.05)); x1.addLine(to: CGPoint(x: m + r * 0.9, y: m + r * 1.0))
        let x2 = UIBezierPath()
        x2.move(to: CGPoint(x: m + r * 0.95, y: m - r * 1.0)); x2.addLine(to: CGPoint(x: m - r * 0.9, y: m + r * 1.05))
        let shapes = [ring(0, 0), ring(-s * 0.02, 0.6), x1, x2]
        // contorno nero
        c.setStrokeColor(UIColor(hex: 0x111111).cgColor)
        c.setLineWidth(s * 0.16)
        for p in shapes { c.addPath(p.cgPath) }
        c.strokePath()
        // tratto rosso
        c.setStrokeColor(red.cgColor)
        c.setLineWidth(s * 0.09)
        for p in shapes { c.addPath(p.cgPath) }
        c.strokePath()
    }

    // MARK: Crimson Heat — stella rosa a cinque punte con contorno nero spesso

    private static func pinkStar(_ c: CGContext, _ s: CGFloat, color: UIColor = UIColor(hex: 0xE46BB0)) {
        let m = CGPoint(x: s / 2, y: s * 0.53)
        let outer = s * 0.4, inner = s * 0.19
        let star = UIBezierPath()
        for i in 0..<10 {
            let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
            let r = i % 2 == 0 ? outer : inner
            let pt = CGPoint(x: m.x + cos(a) * r, y: m.y + sin(a) * r)
            if i == 0 { star.move(to: pt) } else { star.addLine(to: pt) }
        }
        star.close()
        c.setLineJoin(.round)
        c.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        c.setStrokeColor(UIColor(hex: 0x0A0A0A).cgColor)
        c.setLineWidth(s * 0.13)
        c.addPath(star.cgPath); c.strokePath()
        c.setShadow(offset: .zero, blur: 0, color: nil)
        c.setFillColor(color.cgColor)
        c.addPath(star.cgPath); c.fillPath()
    }

    // MARK: Canyon Run — due bandiere a scacchi incrociate

    private static func checkeredFlags(_ c: CGContext, _ s: CGFloat) {
        func flag(mirrored: Bool) {
            c.saveGState()
            if mirrored {
                c.translateBy(x: s, y: 0)
                c.scaleBy(x: -1, y: 1)
            }
            // asta inclinata
            // le due aste partono dagli angoli in basso e si incrociano al centro
            c.translateBy(x: s * 0.3, y: s * 0.9)
            c.rotate(by: 0.42)
            let pole = CGRect(x: -s * 0.025, y: -s * 0.78, width: s * 0.05, height: s * 0.8)
            c.setFillColor(UIColor(hex: 0x111111).cgColor)
            c.fill(pole.insetBy(dx: -s * 0.015, dy: -s * 0.015))
            c.setFillColor(UIColor(hex: 0xBDBDBD).cgColor)
            c.fill(pole)
            // telo ondulato a scacchi 4×3
            let w = s * 0.36, h = s * 0.26
            let origin = CGPoint(x: s * 0.025, y: -s * 0.78)
            let cols = 4, rows = 3
            func wave(_ x: CGFloat) -> CGFloat { sin(x / w * .pi * 1.6) * s * 0.025 }
            let outline = UIBezierPath()
            outline.move(to: CGPoint(x: origin.x, y: origin.y + wave(0)))
            for i in 1...12 { let x = w * CGFloat(i) / 12; outline.addLine(to: CGPoint(x: origin.x + x, y: origin.y + wave(x))) }
            for i in stride(from: 12, through: 0, by: -1) { let x = w * CGFloat(i) / 12; outline.addLine(to: CGPoint(x: origin.x + x, y: origin.y + h + wave(x))) }
            outline.close()
            c.setStrokeColor(UIColor(hex: 0x111111).cgColor)
            c.setLineWidth(s * 0.035)
            c.setLineJoin(.round)
            c.addPath(outline.cgPath); c.strokePath()
            c.setFillColor(UIColor.white.cgColor)
            c.addPath(outline.cgPath); c.fillPath()
            c.setFillColor(UIColor(hex: 0x111111).cgColor)
            for col in 0..<cols {
                for row in 0..<rows where (col + row) % 2 == 0 {
                    let x0 = w * CGFloat(col) / CGFloat(cols), x1 = w * CGFloat(col + 1) / CGFloat(cols)
                    let y0 = h * CGFloat(row) / CGFloat(rows), y1 = h * CGFloat(row + 1) / CGFloat(rows)
                    let cell = UIBezierPath()
                    cell.move(to: CGPoint(x: origin.x + x0, y: origin.y + y0 + wave(x0)))
                    cell.addLine(to: CGPoint(x: origin.x + x1, y: origin.y + y0 + wave(x1)))
                    cell.addLine(to: CGPoint(x: origin.x + x1, y: origin.y + y1 + wave(x1)))
                    cell.addLine(to: CGPoint(x: origin.x + x0, y: origin.y + y1 + wave(x0)))
                    cell.close()
                    c.addPath(cell.cgPath); c.fillPath()
                }
            }
            c.restoreGState()
        }
        flag(mirrored: true)
        flag(mirrored: false)
    }

    // MARK: Storm Isle — segnaposto a palloncino giallo con contorno nero e bordo bianco

    private static func balloonPin(_ c: CGContext, _ s: CGFloat, color: UIColor) {
        let m = s / 2
        let r = s * 0.3
        let cy = s * 0.36
        let path = UIBezierPath()
        path.addArc(withCenter: CGPoint(x: m, y: cy), radius: r, startAngle: .pi * 0.78, endAngle: .pi * 0.22, clockwise: true)
        path.addLine(to: CGPoint(x: m, y: s * 0.95))
        path.close()
        c.setLineJoin(.round)
        // solo contorno nero (niente bordo bianco)
        c.setStrokeColor(UIColor(hex: 0x111111).cgColor); c.setLineWidth(s * 0.1)
        c.addPath(path.cgPath); c.strokePath()
        c.setFillColor(color.cgColor)
        c.addPath(path.cgPath); c.fillPath()
        c.setFillColor(UIColor(hex: 0x111111).cgColor)
        let d = s * 0.11
        c.fillEllipse(in: CGRect(x: m - d, y: cy - d, width: d * 2, height: d * 2))
    }
}

/// Indicatore di destinazione del tema, per l'interfaccia SwiftUI (pannelli)
struct DestinationIcon: View {
    let theme: MapTheme
    var size: CGFloat = 24

    var body: some View {
        Image(uiImage: DestinationMarker.image(for: theme, size: size))
            .interpolation(theme.id == "pixel" ? .none : .high)
            .frame(width: size, height: size)
    }
}
