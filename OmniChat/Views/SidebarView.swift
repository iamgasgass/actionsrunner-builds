import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var app
    var close: () -> Void

    @State private var search = ""
    @State private var renaming: Conversation?
    @State private var renameText = ""

    private var filtered: [Conversation] {
        let items = app.store.sorted.filter { !$0.messages.isEmpty }
        guard !search.isEmpty else { return items }
        return items.filter { convo in
            convo.displayTitle.localizedCaseInsensitiveContains(search)
                || convo.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    private var grouped: [(String, [Conversation])] {
        let cal = Calendar.current
        var today: [Conversation] = [], yesterday: [Conversation] = []
        var week: [Conversation] = [], older: [Conversation] = []
        for c in filtered {
            if cal.isDateInToday(c.updatedAt) { today.append(c) }
            else if cal.isDateInYesterday(c.updatedAt) { yesterday.append(c) }
            else if let d = cal.dateComponents([.day], from: c.updatedAt, to: Date()).day, d < 7 { week.append(c) }
            else { older.append(c) }
        }
        return [("Oggi", today), ("Ieri", yesterday), ("Ultimi 7 giorni", week), ("Precedenti", older)]
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Ricerca
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Cerca", text: $search)
                        .textInputAutocapitalization(.never)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.tertiarySystemFill), in: Capsule())

                Button {
                    app.newChat()
                    close()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    SidebarRow(icon: "bubble.left.and.text.bubble.right", title: "Nuova chat") {
                        app.newChat(); close()
                    }

                    if filtered.isEmpty {
                        Text(search.isEmpty ? "Le tue chat appariranno qui." : "Nessun risultato.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 24)
                    }

                    ForEach(grouped, id: \.0) { section in
                        Text(section.0)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 18)
                            .padding(.bottom, 4)

                        ForEach(section.1) { convo in
                            conversationRow(convo)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollDismissesKeyboard(.immediately)

            Divider()

            // Pulsante profilo / impostazioni
            Button {
                app.showSettings = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.accentColor.gradient)
                        Image(systemName: "person.fill").foregroundStyle(.white)
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Impostazioni").font(.body.weight(.medium))
                        Text(app.settings.hasAPIKey ? app.settings.provider.rawValue : "Aggiungi API key")
                            .font(.caption)
                            .foregroundStyle(app.settings.hasAPIKey ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    Image(systemName: "ellipsis").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Color(.systemBackground))
        .alert("Rinomina chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titolo", text: $renameText)
            Button("Annulla", role: .cancel) { renaming = nil }
            Button("Salva") {
                if let r = renaming { app.store.rename(r.id, to: renameText) }
                renaming = nil
            }
        }
    }

    @ViewBuilder
    private func conversationRow(_ convo: Conversation) -> some View {
        let selected = convo.id == app.currentConversationID
        Button {
            app.select(convo)
            close()
        } label: {
            Text(convo.displayTitle)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Color(.tertiarySystemFill) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = convo.title
                renaming = convo
            } label: { Label("Rinomina", systemImage: "pencil") }
            ShareLink(item: transcript(of: convo)) {
                Label("Condividi", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                app.delete(convo)
            } label: { Label("Elimina", systemImage: "trash") }
        }
    }

    private func transcript(of convo: Conversation) -> String {
        convo.messages.map { m in
            (m.role == .user ? "Tu" : (m.modelName ?? "IA")) + ":\n" + m.content
        }.joined(separator: "\n\n")
    }
}

private struct SidebarRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .frame(width: 24)
                Text(title).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
