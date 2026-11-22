import SwiftUI

/// Barra laterale: ora, stato, app recenti, tasto Home e assistente.
struct DockView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var assistant: VoiceAssistant

    var body: some View {
        VStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(timeString(context.date))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .padding(.top, 12)

            HStack(spacing: 3) {
                Image(systemName: "cellularbars")
                Text("5G").font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer(minLength: 4)

            ForEach(state.recents) { app in
                Button {
                    state.open(app)
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        AppIconView(app: app, size: 46)
                        if app == .nowPlaying && media.isPlaying {
                            EqualizerBars()
                                .frame(width: 14, height: 12)
                                .padding(3)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                                .offset(x: 4, y: 4)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(state.currentApp == app ? 0.9 : 0), lineWidth: 2)
                            .padding(-3)
                    )
                }
                .buttonStyle(PressableStyle())
            }

            Spacer(minLength: 4)

            Button {
                state.homeButtonTapped()
            } label: {
                Image(systemName: homeSymbol)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 50, height: 44)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(PressableStyle())

            Button {
                withAnimation { state.showAssistant = true }
                assistant.startListening()
            } label: {
                ZStack {
                    Circle()
                        .fill(AngularGradient(colors: [.pink, .purple, .blue, .cyan, .pink], center: .center))
                        .frame(width: 34, height: 34)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(PressableStyle())
            .padding(.bottom, 12)
        }
        .frame(width: 74)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.35))
    }

    private var homeSymbol: String {
        switch state.screen {
        case .home: return "rectangle.split.2x1.fill"
        default: return "square.grid.3x2.fill"
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = settings.use24h ? "HH:mm" : "h:mm"
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
