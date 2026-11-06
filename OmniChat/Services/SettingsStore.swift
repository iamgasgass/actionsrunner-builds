import Foundation
import Observation

@Observable
final class SettingsStore {
    private let defaults = UserDefaults.standard

    var provider: APIProvider {
        didSet {
            defaults.set(provider.rawValue, forKey: "provider")
            if provider != .custom { baseURL = provider.defaultBaseURL }
            apiKey = KeychainHelper.read(account: provider.rawValue) ?? ""
        }
    }
    var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    var apiKey: String { didSet { KeychainHelper.save(apiKey, account: provider.rawValue) } }

    var selectedModelID: String { didSet { defaults.set(selectedModelID, forKey: "selectedModelID") } }
    var favoriteModels: [AIModel] { didSet { persist(favoriteModels, key: "favoriteModels") } }

    var roleName: String { didSet { defaults.set(roleName, forKey: "roleName") } }
    var personaName: String { didSet { defaults.set(personaName, forKey: "personaName") } }
    var replyLength: ReplyLength { didSet { defaults.set(replyLength.rawValue, forKey: "replyLength") } }
    var replyFormat: ReplyFormat { didSet { defaults.set(replyFormat.rawValue, forKey: "replyFormat") } }
    var language: String { didSet { defaults.set(language, forKey: "language") } }
    var webSearch: Bool { didSet { defaults.set(webSearch, forKey: "webSearch") } }
    var focusMode: Bool { didSet { defaults.set(focusMode, forKey: "focusMode") } }
    var theme: AppTheme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "haptics") } }

    init() {
        let provider = APIProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openRouter
        self.provider = provider
        self.baseURL = defaults.string(forKey: "baseURL") ?? provider.defaultBaseURL
        self.apiKey = KeychainHelper.read(account: provider.rawValue) ?? ""
        self.selectedModelID = defaults.string(forKey: "selectedModelID") ?? ModelCatalog.defaultModelID
        if let data = defaults.data(forKey: "favoriteModels"),
           let models = try? JSONDecoder().decode([AIModel].self, from: data), !models.isEmpty {
            self.favoriteModels = models
        } else {
            self.favoriteModels = ModelCatalog.defaults
        }
        self.roleName = defaults.string(forKey: "roleName") ?? AIRole.all[0].name
        self.personaName = defaults.string(forKey: "personaName") ?? AIPersonaName.all[0]
        self.replyLength = ReplyLength(rawValue: defaults.string(forKey: "replyLength") ?? "") ?? .balanced
        self.replyFormat = ReplyFormat(rawValue: defaults.string(forKey: "replyFormat") ?? "") ?? .mixed
        self.language = defaults.string(forKey: "language") ?? ReplyLanguage.all[0]
        self.webSearch = defaults.bool(forKey: "webSearch")
        self.focusMode = defaults.bool(forKey: "focusMode")
        self.theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        self.hapticsEnabled = defaults.object(forKey: "haptics") as? Bool ?? true
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: - Helpers

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    func displayName(for modelID: String) -> String {
        favoriteModels.first { $0.id == modelID }?.name
            ?? modelID.split(separator: "/").last.map(String.init)
            ?? modelID
    }

    func isFavorite(_ id: String) -> Bool { favoriteModels.contains { $0.id == id } }

    func toggleFavorite(_ model: AIModel) {
        if let i = favoriteModels.firstIndex(where: { $0.id == model.id }) {
            favoriteModels.remove(at: i)
        } else {
            favoriteModels.append(model)
        }
    }

    func resetFavorites() { favoriteModels = ModelCatalog.defaults }

    /// ID da inviare all'API. Con OpenRouter il suffisso ":online" attiva la ricerca web.
    func requestModelID(for modelID: String) -> String {
        if webSearch && provider == .openRouter && !modelID.hasSuffix(":online") {
            return modelID + ":online"
        }
        return modelID
    }

    /// Prompt di sistema costruito dalle opzioni di tono e formato.
    func systemPrompt(modelName: String) -> String {
        var parts: [String] = []
        if personaName != AIPersonaName.all[0] {
            parts.append("Ti chiami \(personaName).")
        } else {
            parts.append("Sei un assistente IA utile (modello: \(modelName)).")
        }
        let role = AIRole.named(roleName)
        if !role.prompt.isEmpty { parts.append(role.prompt) }
        if !replyLength.instruction.isEmpty { parts.append(replyLength.instruction) }
        if !replyFormat.instruction.isEmpty { parts.append(replyFormat.instruction) }
        if language != ReplyLanguage.all[0] {
            parts.append("Rispondi sempre in \(language).")
        } else {
            parts.append("Rispondi nella stessa lingua dell'utente.")
        }
        if focusMode { parts.append("Resta strettamente sull'argomento, senza digressioni o convenevoli.") }
        parts.append("Usa Markdown quando aiuta la leggibilità.")
        return parts.joined(separator: " ")
    }
}
