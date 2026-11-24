import UIKit

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}

/// Texture generate a runtime: niente immagini da distribuire.
enum Textures {
    private static var cache: [String: UIImage] = [:]

    static func pinstripe(_ p: Palette) -> UIImage {
        let key = "stripe-\(p.isDark)"
        if let cached = cache[key] { return cached }
        let size = CGSize(width: 7, height: 4)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            p.stripeBase.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            p.stripeLine.setFill()
            ctx.fill(CGRect(x: 4, y: 0, width: 3, height: size.height))
        }
        cache[key] = image
        return image
    }

    static func surface(_ p: Palette) -> UIImage {
        let key = "surface-\(p.isDark)"
        if let cached = cache[key] { return cached }
        let image = p.surfaceIsLinen ? linen(base: p.surfaceBase) : brushed(base: p.surfaceBase)
        cache[key] = image
        return image
    }

    /// Lino scuro (lo stesso materiale del Centro Notifiche di iOS 6).
    private static func linen(base: UIColor) -> UIImage {
        let side: CGFloat = 128
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            let ctx = c.cgContext
            base.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var rng = SeededRandom(seed: 6)
            for _ in 0..<7000 {
                let x = rng.next() * side, y = rng.next() * side
                let light = rng.next() > 0.5
                let alpha = 0.03 + rng.next() * 0.06
                ctx.setFillColor((light ? UIColor.white : UIColor.black).withAlphaComponent(alpha).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 0.5, height: 0.5))
            }
            ctx.setLineWidth(0.5)
            for _ in 0..<800 {
                let horizontal = rng.next() > 0.5
                let x = rng.next() * side, y = rng.next() * side
                let len = 3 + rng.next() * 16
                let light = rng.next() > 0.55
                let alpha = 0.035 + rng.next() * 0.06
                ctx.setStrokeColor((light ? UIColor.white : UIColor.black).withAlphaComponent(alpha).cgColor)
                for dx in [0, -side] {
                    for dy in [0, -side] {
                        ctx.move(to: CGPoint(x: x + dx, y: y + dy))
                        ctx.addLine(to: horizontal ? CGPoint(x: x + dx + len, y: y + dy) : CGPoint(x: x + dx, y: y + dy + len))
                    }
                }
                ctx.strokePath()
            }
        }
    }

    /// Alluminio spazzolato.
    private static func brushed(base: UIColor) -> UIImage {
        let w: CGFloat = 256, h: CGFloat = 128
        let size = CGSize(width: w, height: h)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { c in
            let ctx = c.cgContext
            base.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            var rng = SeededRandom(seed: 11)
            ctx.setLineWidth(0.5)
            var y: CGFloat = 0.25
            while y < h {
                let light = rng.next() > 0.5
                ctx.setStrokeColor((light ? UIColor.white : UIColor.black).withAlphaComponent(rng.next() * 0.07).cgColor)
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: w, y: y))
                ctx.strokePath()
                y += 0.5
            }
            for _ in 0..<420 {
                let x = rng.next() * w, yy = rng.next() * h
                let len = 20 + rng.next() * 120
                let light = rng.next() > 0.45
                ctx.setStrokeColor((light ? UIColor.white : UIColor.black).withAlphaComponent(0.03 + rng.next() * 0.07).cgColor)
                for dx in [0, -w] {
                    ctx.move(to: CGPoint(x: x + dx, y: yy))
                    ctx.addLine(to: CGPoint(x: x + dx + len, y: yy))
                }
                ctx.strokePath()
            }
        }
    }
}
