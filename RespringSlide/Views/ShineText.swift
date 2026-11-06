import SwiftUI

/// A single text label with a continuous specular shine sweeping left → right,
/// as on the iOS "slide to power off" label. The base text and the bright
/// (masked) text are the exact same intrinsically-sized `Text`, stacked via an
/// overlay, so they are always perfectly aligned — no ghosting.
///
/// The sweep is driven by `TimelineView(.animation)`, so it is genuinely
/// continuous: it never stutters or stops when the parent view re-renders
/// (dragging, theme changes, …), unlike an `onAppear` `repeatForever`.
struct ShineText: View {
    let text: String
    let font: Font
    var baseOpacity: Double = 0.34
    var bandWidth: CGFloat = 0.5
    var duration: Double = 2.0
    var textColor: Color = .white
    var shineColor: Color = .white

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let frac = CGFloat((t / duration).truncatingRemainder(dividingBy: 1))
            // Band sweeps from just off the left to just off the right.
            let phase = -bandWidth + frac * (1 + bandWidth)

            Text(text)
                .font(font)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(textColor.opacity(baseOpacity))
                .overlay {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(shineColor)
                        .mask {
                            GeometryReader { geo in
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .white, location: 0.5),
                                        .init(color: .clear, location: 1.0)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: geo.size.width * bandWidth)
                                .offset(x: phase * geo.size.width)
                                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                            }
                        }
                }
        }
    }
}
