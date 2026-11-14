import SwiftUI

// MARK: - Liquid Glass (iOS 26, API native SwiftUI)

/// Pulsante/contenitore circolare in Liquid Glass nativo.
struct GlassCircle<Content: View>: View {
    var size: CGFloat = 44
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.tint(tint).interactive(), in: Circle())
    }
}

struct BackCircleButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            GlassCircle(size: 44) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Stile "nessun effetto": la reazione al tocco la fa il Liquid Glass interattivo.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// Pulsante capsula in Liquid Glass (Continua / Ottieni indicazioni / Inizia ora / Termina percorso)
struct GlassCapsuleButton: View {
    var title: String
    var icon: String? = nil
    var height: CGFloat = 54
    var tint: Color = Color.white.opacity(0.9)
    var foreground: Color = .black
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 16, weight: .semibold))
                if let icon = icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .bold))
                }
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Capsule())
            .glassEffect(.regular.tint(tint).interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Compatibilità con il codice precedente
typealias WhiteCapsuleButton = GlassCapsuleButton

/// Icona "impostazioni" a ciambella (come nell'originale).
struct DonutIcon: View {
    var body: some View {
        Circle()
            .strokeBorder(Color.white, lineWidth: 5.5)
            .frame(width: 19, height: 19)
    }
}

/// Segnaposto blu a goccia del pulsante centrale.
struct BluePinIcon: View {
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            Image(systemName: "drop.fill")
                .font(.system(size: size, weight: .regular))
                .rotationEffect(.degrees(180))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: 0x5BB0FF), Color(hex: 0x0A6CFF)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: Color(hex: 0x0A6CFF).opacity(0.9), radius: 7)
            Circle()
                .fill(Color(hex: 0x0A1E3D))
                .frame(width: size * 0.3, height: size * 0.3)
                .offset(y: -size * 0.11)
        }
    }
}

/// Quadrifoglio in SwiftUI (stesso disegno dell'icona mappa)
struct CloverIcon: View {
    var color: Color = Color(hex: 0x8840D8)
    var size: CGFloat = 22

    var body: some View {
        let petal = size * 0.36
        let off = petal * 0.62
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                let dx: CGFloat = i == 2 ? -off : (i == 3 ? off : 0)
                let dy: CGFloat = i == 0 ? -off : (i == 1 ? off : 0)
                Circle().fill(color).frame(width: petal, height: petal).offset(x: dx, y: dy)
            }
            Circle().fill(color).frame(width: petal * 1.1, height: petal * 1.1)
            Circle().fill(Color.white.opacity(0.9)).frame(width: petal * 0.4, height: petal * 0.4)
        }
        .frame(width: size, height: size)
    }
}

/// Pannello inferiore flottante in Liquid Glass, con maniglia.
/// Si chiude con uno swipe verso il basso breve (60 pt) o con un colpo veloce, da qualunque punto del pannello.
struct BottomPanel<Content: View>: View {
    var onDismiss: (() -> Void)?
    @ViewBuilder var content: Content
    @State private var drag: CGFloat = 0
    @State private var panelHeight: CGFloat = 320
    @State private var closing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.4))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(Rectangle())
            content
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
        .glassEffect(.regular.tint(Color.black.opacity(0.35)),
                     in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { panelHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in panelHeight = h }
            }
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .offset(y: drag)
        .simultaneousGesture(dismissGesture)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                guard !closing else { return }
                let t = value.translation.height
                // verso il basso segue il dito; verso l'alto effetto elastico
                drag = t >= 0 ? t : -pow(-t, 0.6)
            }
            .onEnded { value in
                guard !closing else { return }
                let far = value.translation.height > 60
                let fast = value.predictedEndTranslation.height > 150
                if let onDismiss = onDismiss, far || fast {
                    closing = true
                    withAnimation(.easeOut(duration: 0.2)) { drag = panelHeight + 80 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDismiss()
                        drag = 0
                        closing = false
                    }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { drag = 0 }
                }
            }
    }
}

/// Riquadro tratteggiato per gli stati vuoti.
struct DashedEmptyCard: View {
    var icon: String
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .glassEffect(.regular, in: Circle())
                .padding(.bottom, 10)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.28))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        )
    }
}

/// Riga/riquadro in Liquid Glass (ricerca, impostazioni, salvati)
struct GlassRowBackground: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassEffect(.regular.tint(tint).interactive(),
                         in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassRow(cornerRadius: CGFloat = 24, tint: Color? = nil) -> some View {
        modifier(GlassRowBackground(cornerRadius: cornerRadius, tint: tint))
    }
}
