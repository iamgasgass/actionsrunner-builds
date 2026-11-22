import SwiftUI
import UniformTypeIdentifiers

/// Installazione e gestione delle app CarPlay (solo IPA compatibili con CarPlay).
struct AppManagerView: View {
    let close: () -> Void
    @EnvironmentObject var library: AppLibrary
    @EnvironmentObject var runtime: GuestRuntime
    @EnvironmentObject var state: AppState
    @State private var importing = false
    @State private var pendingDelete: GuestApp?

    private var ipaTypes: [UTType] {
        var types: [UTType] = []
        if let ipa = UTType("com.apple.itunes.ipa") { types.append(ipa) }
        if let ipa = UTType(filenameExtension: "ipa") { types.append(ipa) }
        types.append(.zip)
        types.append(.data)
        return types
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: "App CarPlay", back: close) {
                Button {
                    importing = true
                } label: {
                    Label("Installa IPA", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.blue, in: Capsule())
                        .foregroundColor(.white)
                }
                .buttonStyle(PressableStyle())
                .disabled(library.isImporting)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if library.isImporting || library.message != nil {
                        HStack(spacing: 10) {
                            if library.isImporting { ProgressView() }
                            Text(library.message ?? "")
                                .font(.system(size: 14))
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .card(radius: 12)
                    }

                    if library.apps.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "car.rear.and.tire.marks")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text("Nessuna app CarPlay installata")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Tocca \"Installa IPA\" e scegli un file .ipa. Vengono accettate solo app che supportano CarPlay (scena CPTemplateApplicationScene o entitlement com.apple.developer.carplay-*).")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .card()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(library.apps) { app in
                                row(app)
                                if app != library.apps.last { Divider().padding(.leading, 74) }
                            }
                        }
                        .card()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Come funziona")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("""
                        • L'app viene caricata dentro CarPlayss e collegata a una scena CarPlay simulata: i suoi template (liste, griglie, Now Playing, mappe, ecc.) vengono disegnati come su un'unità CarPlay.
                        • IPA importate: il codice non è firmato, quindi servono LiveContainer con JIT attivo (o un dispositivo senza verifica della firma).
                        • Senza JIT: metti le IPA nella cartella EmbeddedApps del repository e ricompila; LiveContainer firma tutto all'installazione.
                        • Le IPA dell'App Store sono criptate e non possono essere usate.
                        """)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .card(radius: 12)
                }
                .padding(14)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ipaTypes, allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                library.importIPA(from: url)
            }
        }
        .alert("Rimuovere l'app?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Rimuovi", role: .destructive) {
                if let app = pendingDelete {
                    state.removeGuest(app.id)
                    library.delete(app)
                }
                pendingDelete = nil
            }
            Button("Annulla", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.name ?? "")
        }
    }

    private func row(_ app: GuestApp) -> some View {
        HStack(spacing: 12) {
            GuestIconView(app: app, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text([app.version.isEmpty ? nil : "v\(app.version)",
                      app.report.categories.isEmpty ? nil : app.report.categories.joined(separator: ", "),
                      app.source.rawValue].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if runtime.sessions[app.id] != nil {
                    Text("In esecuzione").font(.system(size: 12, weight: .semibold)).foregroundColor(.green)
                } else if runtime.errors[app.id] != nil {
                    Text("Errore all'avvio").font(.system(size: 12, weight: .semibold)).foregroundColor(.orange)
                }
            }
            Spacer()
            Button {
                state.open(.guest(app.id))
            } label: {
                Text("Apri")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
            .buttonStyle(PressableStyle())
            if app.source == .imported {
                Button {
                    pendingDelete = app
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
