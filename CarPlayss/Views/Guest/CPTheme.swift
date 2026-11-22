import CarPlay
import SwiftUI

/// Metriche e colori dei template di sistema CarPlay (tema scuro).
enum CP {
    static let background = Color.black
    static let rowBackground = Color.black
    static let separator = Color(white: 0.22)
    static let secondaryText = Color(white: 0.62)
    static let tertiaryText = Color(white: 0.45)
    static let buttonFill = Color(white: 0.20)
    static let buttonFillPressed = Color(white: 0.32)
    static let panel = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)

    static let navBarHeight: CGFloat = 44
    static let rowMinHeight: CGFloat = 50
    static let rowImage: CGFloat = 40
    static let horizontalPadding: CGFloat = 16

    static let titleFont = Font.system(size: 17, weight: .semibold)
    static let rowFont = Font.system(size: 17, weight: .regular)
    static let detailFont = Font.system(size: 14, weight: .regular)
    static let headerFont = Font.system(size: 15, weight: .semibold)
}

/// Pulsante a capsula grigia usato nella barra di navigazione CarPlay.
struct CPCapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(minWidth: 36, minHeight: 32)
            .background(
                Capsule().fill(prominent ? CP.accent : (configuration.isPressed ? CP.buttonFillPressed : CP.buttonFill))
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Sfondo evidenziato al tocco delle righe di lista.
struct CPRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(white: 0.18) : Color.clear)
    }
}

/// Barra di navigazione dei template CarPlay: indietro, pulsanti a sinistra, titolo centrato, pulsanti a destra.
struct CPNavigationBar<Center: View>: View {
    @ObservedObject var session: GuestSession
    let template: CPTemplate
    var title: String?
    @ViewBuilder var center: () -> Center

    var body: some View {
        let provider = template as? CPBarButtonProviding
        ZStack {
            HStack(spacing: 8) {
                if session.stack.count > 1 || provider?.backButton != nil {
                    Button {
                        if let custom = provider?.backButton {
                            session.tap(handlerOf: custom, label: "Indietro")
                        } else {
                            session.back()
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                            if let t = provider?.backButton?.title, !t.isEmpty {
                                Text(t)
                            }
                        }
                    }
                    .buttonStyle(CPCapsuleButtonStyle())
                }
                ForEach(Array((provider?.leadingNavigationBarButtons ?? []).enumerated()), id: \.offset) { _, button in
                    CPBarButtonView(button: button, session: session)
                }
                Spacer(minLength: 0)
                ForEach(Array((provider?.trailingNavigationBarButtons ?? []).enumerated()), id: \.offset) { _, button in
                    CPBarButtonView(button: button, session: session)
                }
            }
            .padding(.horizontal, 10)

            Group {
                if let title = title, !title.isEmpty {
                    Text(title)
                        .font(CP.titleFont)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 130)
                } else {
                    center()
                }
            }
        }
        .frame(height: CP.navBarHeight)
        .frame(maxWidth: .infinity)
        .background(CP.background)
    }
}

extension CPNavigationBar where Center == EmptyView {
    init(session: GuestSession, template: CPTemplate, title: String?) {
        self.session = session
        self.template = template
        self.title = title
        self.center = { EmptyView() }
    }
}

struct CPBarButtonView: View {
    let button: CPBarButton
    @ObservedObject var session: GuestSession

    var body: some View {
        Button {
            session.tap(handlerOf: button, label: "Pulsante")
        } label: {
            if let image = button.image {
                Image(uiImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
            } else {
                Text(button.title ?? "")
            }
        }
        .buttonStyle(CPCapsuleButtonStyle())
        .disabled(!button.isEnabled)
        .opacity(button.isEnabled ? 1 : 0.4)
    }
}

/// Immagine fornita dall'app (UIImage) o segnaposto.
struct CPImage: View {
    let image: UIImage?
    var size: CGFloat
    var radius: CGFloat = 6
    var template = false

    var body: some View {
        if let image = image {
            Image(uiImage: image)
                .renderingMode(template || image.renderingMode == .alwaysTemplate ? .template : .original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .foregroundColor(.white)
        }
    }
}

/// Indicatore "in riproduzione" (barre animate) delle liste audio.
struct CPPlayingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(CP.accent)
                    .frame(width: 3, height: phase ? [14, 6, 11, 8][i] : [5, 13, 7, 12][i])
            }
        }
        .frame(width: 20, height: 14, alignment: .bottom)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) { phase = true }
        }
    }
}

extension CPTemplate {
    /// Titolo mostrato nella barra di navigazione.
    var cpsTitle: String? {
        if let t = self as? CPListTemplate { return t.title }
        if let t = self as? CPGridTemplate { return t.title }
        if let t = self as? CPInformationTemplate { return t.title }
        if let t = self as? CPPointOfInterestTemplate { return t.title }
        return nil
    }
}

extension UITabBarItem.SystemItem {
    var cpsSymbol: String {
        switch self {
        case .bookmarks: return "book.fill"
        case .contacts: return "person.crop.circle.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .favorites: return "star.fill"
        case .featured: return "star.fill"
        case .history: return "clock.fill"
        case .mostRecent: return "clock.fill"
        case .mostViewed: return "list.number"
        case .recents: return "clock.fill"
        case .search: return "magnifyingglass"
        case .topRated: return "star.fill"
        case .more: return "ellipsis"
        @unknown default: return "square.grid.2x2.fill"
        }
    }

    var cpsTitle: String {
        switch self {
        case .bookmarks: return "Segnalibri"
        case .contacts: return "Contatti"
        case .downloads: return "Download"
        case .favorites: return "Preferiti"
        case .featured: return "In evidenza"
        case .history: return "Cronologia"
        case .mostRecent: return "Più recenti"
        case .mostViewed: return "Più visti"
        case .recents: return "Recenti"
        case .search: return "Cerca"
        case .topRated: return "Più votati"
        case .more: return "Altro"
        @unknown default: return ""
        }
    }
}
