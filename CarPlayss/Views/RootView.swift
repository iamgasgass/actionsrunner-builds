import SwiftUI

/// Contenitore: simula il display dell'auto con la risoluzione scelta, scalato per stare nello schermo.
struct RootView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var assistant: VoiceAssistant
    @EnvironmentObject var runtime: GuestRuntime

    var body: some View {
        GeometryReader { geo in
            let bezel: CGFloat = settings.showBezel ? 14 : 0
            let available = CGSize(width: max(1, geo.size.width - bezel * 2 - 8),
                                   height: max(1, geo.size.height - bezel * 2 - 8))
            ZStack {
                Color.black

                if let logical = settings.displayPreset.logicalSize {
                    let scale = min(available.width / logical.width, available.height / logical.height)
                    screen
                        .frame(width: logical.width, height: logical.height)
                        .modifier(BezelModifier(enabled: settings.showBezel, width: bezel / max(scale, 0.01)))
                        .scaleEffect(scale)
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    screen
                        .frame(width: available.width, height: available.height)
                        .modifier(BezelModifier(enabled: settings.showBezel, width: bezel))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .onAppear(perform: wireUp)
        .onChange(of: settings.simulationSpeed) { nav.simulationMultiplier = $0 }
        .onChange(of: settings.spokenFeedback) { assistant.speakResponses = $0 }
        .onChange(of: settings.appearance) { runtime.contentStyleChanged(dark: $0 != .light) }
    }

    private var screen: some View {
        CarScreenView()
            .clipShape(RoundedRectangle(cornerRadius: settings.showBezel ? 22 : 0, style: .continuous))
    }

    private func wireUp() {
        nav.simulationMultiplier = settings.simulationSpeed
        assistant.speakResponses = settings.spokenFeedback
        let state = self.state
        let media = self.media
        let nav = self.nav
        assistant.handler = { text in
            CommandBrain.handle(text, state: state, media: media, nav: nav)
        }
    }
}

struct BezelModifier: ViewModifier {
    let enabled: Bool
    let width: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(width)
                .background(
                    RoundedRectangle(cornerRadius: 22 + width, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22 + width, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.6), radius: 18)
                )
        } else {
            content
        }
    }
}
