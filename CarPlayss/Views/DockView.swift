import SwiftUI

/// Barra di stato laterale in stile CarPlay: ora, rete, tre app recenti e tasto Home.
/// Tieni premuto il tasto Home per l'assistente vocale.
struct DockView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var assistant: VoiceAssistant

    var body: some View {
        GeometryReader { geo in
            let icon = min(52, max(40, (geo.size.height - 190) / 3.4))
            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(timeString(context.date))
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.top, 12)

                HStack(spacing: 3) {
                    Image(systemName: "cellularbars")
                        .font(.system(size: 11, weight: .semibold))
                    Text("5G")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.top, 4)

                Spacer(minLength: 8)

                VStack(spacing: 14) {
                    ForEach(state.recents) { item in
                        Button {
                            state.open(item)
                        } label: {
                            ZStack(alignment: .bottomTrailing) {
                                HomeIconView(item: item, size: icon)
                                if item == .builtin(.nowPlaying) && media.isPlaying {
                                    EqualizerBars()
                                        .frame(width: 12, height: 10)
                                        .padding(3)
                                        .background(Circle().fill(Color.black.opacity(0.7)))
                                        .offset(x: 4, y: 4)
                                }
                            }
                        }
                        .buttonStyle(PressableStyle())
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: homeSymbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 50)
                    .contentShape(Rectangle())
                    .onTapGesture { state.homeButtonTapped() }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        withAnimation { state.showAssistant = true }
                        assistant.startListening()
                    }
                    .padding(.bottom, 10)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(width: 76)
        .background(Color.black)
    }

    private var homeSymbol: String {
        switch state.screen {
        case .home: return "rectangle.split.1x2"
        default: return "square.grid.3x3.fill"
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = settings.use24h ? "H:mm" : "h:mm"
        return f.string(from: date)
    }
}

struct EqualizerBars: View {
    @State private var animate = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.pink)
                    .frame(width: 2.5)
                    .scaleEffect(y: animate ? [1.0, 0.4, 0.8][i] : [0.3, 1.0, 0.5][i], anchor: .bottom)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

/// Icona di un elemento Home (integrata o app installata).
struct HomeIconView: View {
    let item: HomeItem
    var size: CGFloat
    @EnvironmentObject var library: AppLibrary

    var body: some View {
        switch item {
        case .builtin(let app):
            AppIconView(app: app, size: size)
        case .guest(let id):
            if let app = library.app(id: id) {
                GuestIconView(app: app, size: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(Color(white: 0.25))
                    .frame(width: size, height: size)
            }
        }
    }
}

/// Icona di un'app CarPlay installata, con la maschera arrotondata di CarPlay.
struct GuestIconView: View {
    let app: GuestApp
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = app.icon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.45), Color(white: 0.25)], startPoint: .top, endPoint: .bottom)
                    Text(String(app.name.prefix(1)))
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}
