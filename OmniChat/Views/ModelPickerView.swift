import SwiftUI

struct ModelPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable { case favorites = "Preferiti", all = "Tutti i modelli" }

    @State private var tab: Tab = .favorites
    @State private var search = ""
    @State private var allModels: [AIModel] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var showAddCustom = false
    @State private var customID = ""
    @State private var customName = ""

    private var filteredFavorites: [AIModel] {
        guard !search.isEmpty else { return app.settings.favoriteModels }
        return app.settings.favoriteModels.filter { matches($0) }
    }

    private var groupedAll: [(String, [AIModel])] {
        let items = search.isEmpty ? allModels : allModels.filter { matches($0) }
        let dict = Dictionary(grouping: items, by: \.provider)
        return dict.keys.sorted().map { ($0, dict[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                switch tab {
                case .favorites: favoritesContent
                case .all: allContent
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Cerca modelli")
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground))
            }
            .navigationTitle("Modelli")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            customID = ""; customName = ""; showAddCustom = true
                        } label: { Label("Aggiungi ID modello", systemImage: "plus") }
                        Button(role: .destructive) {
                            app.settings.resetFavorites()
                        } label: { Label("Ripristina predefiniti", systemImage: "arrow.counterclockwise") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
            .task(id: tab) {
                if tab == .all && allModels.isEmpty { await load() }
            }
            .alert("Aggiungi modello", isPresented: $showAddCustom) {
                TextField("ID (es. openai/gpt-5)", text: $customID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Nome visualizzato", text: $customName)
                Button("Annulla", role: .cancel) {}
                Button("Aggiungi") {
                    let id = customID.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty else { return }
                    let model = AIModel(id: id, name: customName.isEmpty ? id : customName)
                    if !app.settings.isFavorite(id) { app.settings.favoriteModels.append(model) }
                }
            } message: {
                Text("Inserisci l'ID esatto del modello come indicato dal tuo provider.")
            }
        }
    }

    // MARK: - Contenuti

    @ViewBuilder
    private var favoritesContent: some View {
        Section {
            ForEach(filteredFavorites) { model in
                modelRow(model, showStar: false)
            }
            .onDelete { offsets in
                let ids = offsets.map { filteredFavorites[$0].id }
                app.settings.favoriteModels.removeAll { ids.contains($0.id) }
            }
            .onMove { from, to in
                guard search.isEmpty else { return }
                app.settings.favoriteModels.move(fromOffsets: from, toOffset: to)
            }
        } footer: {
            Text("Scorri a sinistra per rimuovere. Trova altri modelli in \"Tutti i modelli\".")
        }
    }

    @ViewBuilder
    private var allContent: some View {
        if loading {
            HStack { Spacer(); ProgressView("Caricamento…"); Spacer() }
                .listRowBackground(Color.clear)
        } else if let loadError {
            Section {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                Button("Riprova") { Task { await load() } }
            }
        } else {
            ForEach(groupedAll, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { model in
                        modelRow(model, showStar: true)
                    }
                }
            }
        }
    }

    private func modelRow(_ model: AIModel, showStar: Bool) -> some View {
        let selected = model.id == app.settings.selectedModelID
        return HStack(spacing: 12) {
            ProviderBadge(provider: model.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).font(.body.weight(.medium)).lineLimit(1)
                Text(model.id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if showStar {
                Button {
                    app.settings.toggleFavorite(model)
                } label: {
                    Image(systemName: app.settings.isFavorite(model.id) ? "star.fill" : "star")
                        .foregroundStyle(app.settings.isFavorite(model.id) ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
            }
            if selected {
                Image(systemName: "checkmark").font(.body.weight(.semibold))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            app.selectModel(model)
            dismiss()
        }
    }

    private func matches(_ model: AIModel) -> Bool {
        model.name.localizedCaseInsensitiveContains(search)
            || model.id.localizedCaseInsensitiveContains(search)
            || model.provider.localizedCaseInsensitiveContains(search)
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let service = ChatService(baseURL: app.settings.baseURL, apiKey: app.settings.apiKey)
            allModels = try await service.fetchModels()
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Badge circolare con le iniziali del provider (niente loghi di terze parti).
struct ProviderBadge: View {
    let provider: String

    private var color: Color {
        let palette: [Color] = [.green, .orange, .blue, .purple, .pink, .teal, .indigo, .red, .mint, .brown]
        let hash = provider.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    var body: some View {
        Text(String(provider.prefix(2)))
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(color.gradient))
    }
}
