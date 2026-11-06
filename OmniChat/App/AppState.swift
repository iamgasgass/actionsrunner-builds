import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class AppState {
    let settings = SettingsStore()
    let store = ConversationStore()

    var currentConversationID: UUID?
    var isStreaming = false
    var errorMessage: String?
    var showSettings = false

    private var streamTask: Task<Void, Never>?

    var currentConversation: Conversation? {
        store.conversation(id: currentConversationID)
    }

    var currentModelName: String {
        settings.displayName(for: settings.selectedModelID)
    }

    // MARK: - Navigazione chat

    func newChat() {
        stopStreaming()
        currentConversationID = nil
        store.pruneEmpty(except: nil)
        haptic(.light)
    }

    func select(_ conversation: Conversation) {
        stopStreaming()
        currentConversationID = conversation.id
        settings.selectedModelID = conversation.modelID
    }

    func delete(_ conversation: Conversation) {
        if conversation.id == currentConversationID { newChat() }
        store.delete(conversation.id)
    }

    func selectModel(_ model: AIModel) {
        settings.selectedModelID = model.id
        if let id = currentConversationID {
            store.update(id) { $0.modelID = model.id }
        }
        haptic(.light)
    }

    // MARK: - Invio messaggi

    func send(text: String, imageData: Data?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isStreaming, !trimmed.isEmpty || imageData != nil else { return }
        guard settings.hasAPIKey else {
            errorMessage = ChatServiceError.missingKey.errorDescription
            showSettings = true
            return
        }

        let conversationID: UUID
        if let id = currentConversationID {
            conversationID = id
        } else {
            conversationID = store.create(modelID: settings.selectedModelID).id
            currentConversationID = conversationID
        }

        let userMessage = ChatMessage(role: .user, content: trimmed, imageData: imageData)
        store.update(conversationID) { convo in
            convo.messages.append(userMessage)
            convo.updatedAt = Date()
            if convo.title.isEmpty {
                let base = trimmed.isEmpty ? "Immagine" : trimmed
                convo.title = String(base.replacingOccurrences(of: "\n", with: " ").prefix(48))
            }
        }
        haptic(.medium)
        startCompletion(in: conversationID)
    }

    /// Rigenera l'ultima risposta dell'assistente.
    func regenerate() {
        guard !isStreaming, let id = currentConversationID,
              let convo = store.conversation(id: id),
              let last = convo.messages.last, last.role == .assistant else { return }
        store.update(id) { $0.messages.removeLast() }
        startCompletion(in: id)
    }

    /// Modifica un messaggio dell'utente e rigenera da quel punto.
    func edit(message: ChatMessage, newText: String) {
        guard !isStreaming, let id = currentConversationID else { return }
        store.update(id) { convo in
            guard let i = convo.messages.firstIndex(where: { $0.id == message.id }) else { return }
            convo.messages[i].content = newText
            convo.messages.removeSubrange((i + 1)...)
        }
        startCompletion(in: id)
    }

    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
    }

    private func startCompletion(in conversationID: UUID) {
        guard let convo = store.conversation(id: conversationID) else { return }

        let modelID = settings.selectedModelID
        let modelName = settings.displayName(for: modelID)
        let system = settings.systemPrompt(modelName: modelName)
        let history = convo.messages
        let service = ChatService(baseURL: settings.baseURL, apiKey: settings.apiKey)
        let requestModel = settings.requestModelID(for: modelID)

        let assistantID = UUID()
        store.update(conversationID, save: false) { convo in
            convo.modelID = modelID
            convo.messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", modelName: modelName))
        }

        isStreaming = true
        errorMessage = nil

        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let messages = ChatService.apiMessages(system: system, history: history)
                for try await chunk in service.stream(model: requestModel, messages: messages) {
                    self.store.update(conversationID, save: false) { convo in
                        if let i = convo.messages.firstIndex(where: { $0.id == assistantID }) {
                            convo.messages[i].content += chunk
                        }
                    }
                }
            } catch is CancellationError {
                // Interrotto dall'utente
            } catch let error as URLError where error.code == .cancelled {
                // Interrotto dall'utente
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.store.update(conversationID, save: false) { convo in
                    if let i = convo.messages.firstIndex(where: { $0.id == assistantID }) {
                        convo.messages[i].content = text
                        convo.messages[i].isError = true
                    }
                }
                self.haptic(.heavy)
            }

            self.store.update(conversationID) { convo in
                // Rimuove la bolla vuota se la generazione è stata interrotta subito
                convo.messages.removeAll { $0.id == assistantID && $0.content.isEmpty }
                convo.updatedAt = Date()
            }
            self.isStreaming = false
            self.streamTask = nil
        }
    }

    // MARK: - Haptics

    func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard settings.hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
