import SwiftUI

/// The "Respring" section. Hosts the two skins and the shared respring engine,
/// and overlays the theme picker (top-right). The picker itself matches the
/// active skin: a native Liquid Glass "…" in Liquid Glass mode, and the
/// OldSafari iOS 6 sheet-metal "…" with a history-style dropdown in OldOS mode.
///
/// The engine (`RespringPayloadView`) lives here so both skins trigger the
/// identical behaviour: slide → (optional confirm) → run.
struct RootPowerView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var isRunning = false
    @State private var engineEnabled = false
    @State private var showingOldOSMenu = false

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            // Active skin.
            Group {
                switch settings.skin {
                case .liquidGlass:
                    LiquidGlassPowerOffView(isRunning: isRunning, onArmed: arm)
                case .oldOS:
                    OldOSPowerOffView(isRunning: isRunning, onArmed: arm)
                }
            }
            .transition(.opacity)

            // The embedded engine sits on top once armed.
            if engineEnabled {
                RespringPayloadView()
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            // Theme picker button, styled to match the active skin.
            themePickerButton

            // OldOS dropdown, styled like the OldSafari history panel.
            if showingOldOSMenu {
                OldOSThemeMenuPanel(
                    current: settings.skin,
                    onSelect: { select($0) },
                    onDismiss: { withAnimation(.easeOut(duration: 0.15)) { showingOldOSMenu = false } }
                )
                .transition(.opacity)
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: settings.skin)
    }

    @ViewBuilder
    private var themePickerButton: some View {
        VStack {
            HStack {
                Spacer()
                Group {
                    switch settings.skin {
                    case .liquidGlass:
                        liquidGlassPicker
                    case .oldOS:
                        OldOSEllipsisButton {
                            withAnimation(.easeOut(duration: 0.15)) { showingOldOSMenu.toggle() }
                        }
                    }
                }
                .disabled(isRunning)
                .opacity(isRunning ? 0.35 : 1)
                .padding(.trailing, 18)
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    /// Native Liquid Glass "…" — the identical material as the X button.
    private var liquidGlassPicker: some View {
        Menu {
            Picker("Aspetto", selection: skinBinding) {
                ForEach(AppTheme.allCases) { theme in
                    Label(theme.title, systemImage: theme.symbol)
                        .tag(theme)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle((colorScheme == .dark ? Color.white : Color(white: 0.12)).opacity(0.96))
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Scegli l'aspetto")
    }

    private var skinBinding: Binding<AppTheme> {
        Binding(
            get: { settings.skin },
            set: { select($0) }
        )
    }

    private func select(_ newTheme: AppTheme) {
        settings.skin = newTheme
        withAnimation(.easeOut(duration: 0.15)) { showingOldOSMenu = false }
    }

    private func arm() {
        isRunning = true
        withAnimation(.easeInOut(duration: 0.25)) {
            engineEnabled = true
        }
    }
}

#Preview {
    RootPowerView()
        .environmentObject(AppSettings())
}
