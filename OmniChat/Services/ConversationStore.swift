import Foundation
import Observation

@Observable
final class ConversationStore {
    private(set) var conversations: [Conversation] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }()

    init() { load() }

    var sorted: [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(id: UUID?) -> Conversation? {
        guard let id else { return nil }
        return conversations.first { $0.id == id }
    }

    @discardableResult
    func create(modelID: String) -> Conversation {
        let convo = Conversation(modelID: modelID)
        conversations.append(convo)
        return convo
    }

    func update(_ id: UUID, save shouldSave: Bool = true, _ body: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        body(&conversations[i])
        if shouldSave { save() }
    }

    func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title }
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        save()
    }

    func deleteAll() {
        conversations.removeAll()
        save()
    }

    /// Rimuove le chat rimaste vuote (create ma mai usate).
    func pruneEmpty(except keep: UUID?) {
        let before = conversations.count
        conversations.removeAll { $0.messages.isEmpty && $0.id != keep }
        if conversations.count != before { save() }
    }

    // MARK: - Persistenza

    func save() {
        do {
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            print("Salvataggio chat fallito: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([Conversation].self, from: data) else { return }
        conversations = items.filter { !$0.messages.isEmpty }
    }
}
