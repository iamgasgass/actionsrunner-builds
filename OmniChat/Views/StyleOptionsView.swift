import SwiftUI

/// Opzioni "Tono e formato" come sul sito: ruolo IA, nome IA, lunghezza, formato, lingua.
struct StyleOptionsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section("Ruolo IA") {
                    Picker("Ruolo", selection: $settings.roleName) {
                        ForEach(AIRole.all) { role in
                            Label(role.name, systemImage: role.icon).tag(role.name)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("Nome IA", selection: $settings.personaName) {
                        ForEach(AIPersonaName.all, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Lunghezza risposta") {
                    Picker("Lunghezza", selection: $settings.replyLength) {
                        ForEach(ReplyLength.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section("Formato") {
                    Picker("Formato risposta", selection: $settings.replyFormat) {
                        ForEach(ReplyFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Lingua", selection: $settings.language) {
                        ForEach(ReplyLanguage.all, id: \.self) { Text($0).tag($0) }
                    }
                }

                Section {
                    Toggle(isOn: $settings.webSearch) {
                        Label("Cerca sul web", systemImage: "globe")
                    }
                    Toggle(isOn: $settings.focusMode) {
                        Label("Modalità focus", systemImage: "scope")
                    }
                } footer: {
                    Text("La ricerca web usa il suffisso \":online\" di OpenRouter e può avere un costo aggiuntivo. Con altri provider viene ignorata.")
                }
            }
            .navigationTitle("Tono e formato")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
}
