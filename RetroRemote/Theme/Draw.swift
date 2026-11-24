import UIKit

enum Draw {
    static func gradient(_ colors: [UIColor], _ locations: [CGFloat]? = nil) -> CGGradient {
        let space = CGColorSpaceCreateDeviceRGB()
        let cgColors = colors.map { $0.cgColor } as CFArray
        if let locations = locations {
            return CGGradient(colorsSpace: space, colors: cgColors, locations: locations)!
        }
        return CGGradient(colorsSpace: space, colors: cgColors, locations: nil)!
    }

    /// Riempie `path` con un gradiente verticale che copre `rect`.
    static func fillVertical(_ path: UIBezierPath, _ rect: CGRect, _ colors: [UIColor], _ locations: [CGFloat]? = nil) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        path.addClip()
        ctx.drawLinearGradient(gradient(colors, locations),
                               start: CGPoint(x: rect.midX, y: rect.minY),
                               end: CGPoint(x: rect.midX, y: rect.maxY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    static func text(_ string: String, font: UIFont, color: UIColor,
                     shadow: UIColor? = nil, offset: CGSize = .zero, blur: CGFloat = 0,
                     in rect: CGRect) {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let shadow = shadow {
            let s = NSShadow()
            s.shadowColor = shadow
            s.shadowOffset = offset
            s.shadowBlurRadius = blur
            attrs[.shadow] = s
        }
        let str = string as NSString
        let size = str.size(withAttributes: attrs)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        str.draw(at: origin, withAttributes: attrs)
    }

    static func symbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .bold, color: UIColor) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        return UIImage(systemName: name, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// Simbolo riempito con un gradiente verticale (icone della tab bar iOS 6).
    static func gradientSymbol(_ name: String, pointSize: CGFloat, weight: UIImage.SymbolWeight, colors: [UIColor]) -> UIImage? {
        guard let sym = symbol(name, pointSize: pointSize, weight: weight, color: .black) else { return nil }
        let size = sym.size
        return UIGraphicsImageRenderer(size: size).image { ctx in
            sym.draw(in: CGRect(origin: .zero, size: size))
            ctx.cgContext.setBlendMode(.sourceIn)
            ctx.cgContext.drawLinearGradient(gradient(colors), start: .zero,
                                             end: CGPoint(x: 0, y: size.height), options: [])
        }
    }

    /// Disegna un'immagine centrata con ombra "incisa".
    static func image(_ image: UIImage, centeredIn rect: CGRect, shadow: UIColor? = nil, offset: CGSize = .zero, blur: CGFloat = 0) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        if let shadow = shadow { ctx.setShadow(offset: offset, blur: blur, color: shadow.cgColor) }
        let r = CGRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2,
                       width: image.size.width, height: image.size.height)
        image.draw(in: r)
        ctx.restoreGState()
    }

    /// Riflesso lucido a ellisse delle icone/alert iOS 6.
    static func glossEllipse(in rect: CGRect, top: CGFloat, bottom: CGFloat, heightFactor: CGFloat = 0.55) {
        let oval = CGRect(x: rect.minX - rect.width * 0.5, y: rect.minY - rect.height * (1.45 - heightFactor),
                          width: rect.width * 2, height: rect.height * 1.45)
        let path = UIBezierPath(ovalIn: oval)
        let glossRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * heightFactor)
        fillVertical(path, glossRect, [UIColor(255, 255, 255, top), UIColor(255, 255, 255, bottom)])
    }
}
