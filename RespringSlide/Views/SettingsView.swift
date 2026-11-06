import SwiftUI

/// The "Impostazioni" section: appearance, interface skin, respring behaviour
/// and app information. Rendered with a native `Form`, so it picks up the
/// Liquid Glass styling on iOS 26+.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        if settings.skin == .oldOS {
            // iOS 6 / OldOS settings when the OldOS skin is active.
            OldOSSettingsView()
        } else {
            nativeSettings
        }
    }

    private var nativeSettings: some View {
        NavigationStack {
            Form {
                // MARK: Aspetto
                Section {
                    Picker(selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    } label: {
                        Label("Tema colore", systemImage: "circle.lefthalf.filled")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Aspetto")
                } footer: {
                    Text("“Sistema” segue l'impostazione di iOS; “Chiaro” e “Scuro” forzano l'aspetto dell'app.")
                }

                // MARK: Interfaccia
                Section {
                    Picker(selection: $settings.skin) {
                        ForEach(AppTheme.allCases) { skin in
                            Label(skin.title, systemImage: skin.symbol).tag(skin)
                        }
                    } label: {
                        Label("Stile interfaccia", systemImage: "square.on.square.dashed")
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Interfaccia")
                } footer: {
                    Text(settings.skin == .liquidGlass
                         ? "Liquid Glass: lo slider di spegnimento nativo di iOS 27."
                         : "OldOS: lo slide to power off di iOS 6, UI identica a OldSafari.")
                }

                // MARK: Respring
                Section {
                    Toggle(isOn: $settings.requireConfirmation) {
                        Label("Chiedi conferma", systemImage: "exclamationmark.bubble")
                    }

                    Toggle(isOn: $settings.haptics) {
                        Label("Feedback aptico", systemImage: "iphone.radiowaves.left.and.right")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Soglia di scorrimento", systemImage: "slider.horizontal.3")
                            Spacer()
                            Text("\(Int(settings.threshold * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.threshold, in: 0.6...0.95, step: 0.01)
                    }
                } header: {
                    Text("Respring")
                } footer: {
                    Text("Quanto lontano trascinare il cursore per attivare il respring. Con la conferma attiva, dopo lo slider appare un avviso prima dell'avvio.")
                }

                // MARK: Avanzate
                Section {
                    Button(role: .destructive) {
                        settings.tap(.medium)
                        settings.requireConfirmation = true
                        settings.haptics = true
                        settings.threshold = 0.84
                        settings.appearance = .system
                        settings.skin = .liquidGlass
                    } label: {
                        Label("Ripristina impostazioni", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Avanzate")
                }

                // MARK: Informazioni
                Section {
                    LabeledContent {
                        Text(appVersion).foregroundStyle(.secondary)
                    } label: {
                        Label("Versione", systemImage: "number")
                    }

                    LabeledContent {
                        Text("iamgasgass").foregroundStyle(.secondary)
                    } label: {
                        Label("Autore", systemImage: "person")
                    }
                } header: {
                    Text("Informazioni")
                } footer: {
                    Text("La tecnica di respring è sperimentale e basata su WebKit: può bloccare WebKit, riavviare SpringBoard o non fare nulla, e non è garantita su ogni versione di iOS. Salva il tuo lavoro prima di usarla. Non è un'API supportata da Apple.")
                }
            }
            .navigationTitle("Impostazioni")
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings())
}
