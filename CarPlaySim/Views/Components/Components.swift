import MediaPlayer
import SwiftUI

struct AppIconView: View {
    let app: CarApp
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: app.colors, startPoint: .top, endPoint: .bottom))
            if app == .calendar {
                VStack(spacing: 0) {
                    Text(weekday)
                        .font(.system(size: size * 0.14, weight: .semibold))
                        .foregroundColor(.red)
                    Text(day)
                        .font(.system(size: size * 0.42, weight: .light))
                        .foregroundColor(.black)
                }
            } else {
                Image(systemName: app.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundColor(app.symbolColor)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }

    private var weekday: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEE"
        return f.string(from: Date()).uppercased()
    }

    private var day: String {
        String(Calendar.current.component(.day, from: Date()))
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Riquadro con materiale traslucido usato in Dashboard e nelle app.
struct CardBackground: ViewModifier {
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func card(radius: CGFloat = 18) -> some View {
        modifier(CardBackground(radius: radius))
    }
}

/// Barra superiore delle app (titolo + azioni).
struct AppHeader<Trailing: View>: View {
    let title: String
    var back: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let back = back {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(PressableStyle())
            }
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

extension AppHeader where Trailing == EmptyView {
    init(title: String, back: (() -> Void)? = nil) {
        self.title = title
        self.back = back
        self.trailing = { EmptyView() }
    }
}

/// Copertina: immagine reale se disponibile, altrimenti gradiente generato.
struct ArtworkView: View {
    let image: UIImage?
    let hue: Double
    var symbol: String = "music.note"
    var cornerRadius: CGFloat = 14

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color.hue(hue, s: 0.7, b: 0.95), Color.hue(hue + 0.08 > 1 ? hue - 0.92 : hue + 0.08, s: 0.85, b: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: symbol)
                    .resizable()
                    .scaledToFit()
                    .padding(28)
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct AvatarView: View {
    let initials: String
    let hue: Double
    var size: CGFloat = 44

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color.hue(hue, s: 0.45, b: 0.85), Color.hue(hue, s: 0.7, b: 0.55)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundColor(.white)
            )
    }
}

/// Volume di sistema (slider di MPVolumeView).
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Elemento di lista grande, adatto al tocco in auto.
struct CarListRow<Leading: View>: View {
    let title: String
    var subtitle: String?
    var trailingSymbol: String? = "chevron.right"
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: 14) {
            leading()
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let s = trailingSymbol {
                Image(systemName: s)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}
