import SwiftUI

/// Bagliore dell'atmosfera disegnato esattamente sulla linea dell'orizzonte del globo.
/// Profilo misurato sul video: linea quasi bianca di ~2 pt e coda blu che svanisce in ~40 pt verso lo spazio.
struct GlobeGlow: View {
    let size: CGSize
    let glow: Color
    let core: Color

    var body: some View {
        let pts = GlobeCoordinator.limbPoints(size: size)
        Canvas { ctx, canvasSize in
            guard pts.count > 2 else { return }
            var limb = Path()
            limb.addLines(pts)
            limb.closeSubpath()

            // solo all'esterno del globo (verso lo spazio)
            var outside = Path(CGRect(origin: .zero, size: canvasSize).insetBy(dx: -200, dy: -200))
            outside.addPath(limb)

            ctx.drawLayer { layer in
                layer.clip(to: outside, style: FillStyle(eoFill: true))
                layer.drawLayer { l in
                    l.addFilter(.blur(radius: 16))
                    l.stroke(limb, with: .color(glow.opacity(0.55)), lineWidth: 34)
                }
                layer.drawLayer { l in
                    l.addFilter(.blur(radius: 5))
                    l.stroke(limb, with: .color(glow.opacity(0.75)), lineWidth: 10)
                }
                layer.drawLayer { l in
                    l.addFilter(.blur(radius: 1.6))
                    l.stroke(limb, with: .color(core.opacity(0.85)), lineWidth: 5)
                }
            }
            // linea luminosa sul bordo
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 0.5))
                l.stroke(limb, with: .color(core), lineWidth: 1.6)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
