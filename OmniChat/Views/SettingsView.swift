import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var testing = false
    @State private var testResult: String?
    @State private var confirmDeleteAll = false
    @State private var revealKey = false

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                if let error = app.errorMessage, !settings.hasAPIKey {
                    Section {
                        Label(error, systemImage: "key.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(APIProvider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("Base URL", text: $settings.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    HStack {
                        Group {
                            if revealKey {
                                TextField(settings.provider.keyHint, text: $settings.apiKey)
                            } else {
                                SecureField(settings.provider.keyHint, text: $settings.apiKey)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("Verifica connessione")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    .disabled(testing || !settings.hasAPIKey)
                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connessione")
                } footer: {
                    Text("La chiave è salvata nel Portachiavi del dispositivo e inviata solo al provider scelto. Con OpenRouter una sola chiave dà accesso a GPT, Claude, Gemini, DeepSeek, Grok, Qwen, Llama e molti altri, inclusi modelli gratuiti.")
                }

                if settings.provider == .openRouter {
                    Section {
                        Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                            Label("Ottieni una chiave OpenRouter", systemImage: "arrow.up.right.square")
                        }
                    }
                }

                Section("Aspetto") {
                    Picker("Tema", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Feedback aptico", isOn: $settings.hapticsEnabled)
                }

                Section("Modelli") {
                    LabeledContent("Modello attuale", value: app.currentModelName)
                    LabeledContent("Preferiti", value: "\(settings.favoriteModels.count)")
                    Button("Ripristina modelli predefiniti") { settings.resetFavorites() }
                }

                Section("Dati") {
                    LabeledContent("Chat salvate", value: "\(app.store.conversations.count)")
                    Button("Elimina tutte le chat", role: .destructive) { confirmDeleteAll = true }
                }

                Section {
                    LabeledContent("Versione", value: appVersion)
                } footer: {
                    Text("OmniChat è un client indipendente e non è affiliato con OpenAI, Anthropic, Google o altri fornitori di modelli.")
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") {
                        app.errorMessage = nil
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Eliminare tutte le chat?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Elimina tutto", role: .destructive) {
                    app.newChat()
                    app.store.deleteAll()
                }
            } message: {
                Text("L'operazione non può essere annullata.")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func testConnection() async {
        testing = true
        testResult = nil
        defer { testing = false }
        do {
            let service = ChatService(baseURL: app.settings.baseURL, apiKey: app.settings.apiKey)
            let models = try await service.fetchModels()
            testResult = "✅ Connesso: \(models.count) modelli disponibili."
        } catch {
            testResult = "❌ " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
