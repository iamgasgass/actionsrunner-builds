import Foundation
import SwiftUI

// MARK: - Messaggi e conversazioni

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var role: MessageRole
    var content: String
    var imageData: Data? = nil
    var modelName: String? = nil
    var isError: Bool = false
    var createdAt: Date = Date()
}

struct Conversation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var messages: [ChatMessage] = []
    var modelID: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var displayTitle: String {
        title.isEmpty ? "Nuova chat" : title
    }
}

// MARK: - Modelli IA

struct AIModel: Identifiable, Codable, Hashable {
    /// ID usato dall'API (es. "openai/gpt-5")
    var id: String
    /// Nome mostrato in app (es. "GPT 5")
    var name: String
    /// Fornitore (OpenAI, Anthropic, Google…)
    var provider: String

    init(id: String, name: String, provider: String? = nil) {
        self.id = id
        self.name = name
        self.provider = provider ?? AIModel.guessProvider(from: id)
    }

    static func guessProvider(from id: String) -> String {
        let prefix = id.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
        switch prefix {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "google": return "Google"
        case "deepseek": return "DeepSeek"
        case "x-ai": return "xAI"
        case "qwen": return "Qwen"
        case "meta-llama": return "Meta"
        case "microsoft": return "Microsoft"
        case "moonshotai": return "Moonshot"
        case "z-ai", "thudm": return "Zhipu"
        case "mistralai": return "Mistral"
        default: return prefix.isEmpty ? "Altro" : prefix.capitalized
        }
    }
}

// MARK: - Opzioni di tono e formato (come sul sito)

struct AIRole: Identifiable, Hashable {
    let name: String
    let icon: String
    let prompt: String
    var id: String { name }

    static let all: [AIRole] = [
        AIRole(name: "Predefinito", icon: "sparkles", prompt: ""),
        AIRole(name: "Programmatore", icon: "chevron.left.forwardslash.chevron.right", prompt: "Sei un ingegnere software esperto. Scrivi codice pulito, corretto e commentato, spiegando le scelte."),
        AIRole(name: "Insegnante", icon: "graduationcap", prompt: "Sei un insegnante paziente. Spiega in modo semplice, con esempi, e verifica la comprensione."),
        AIRole(name: "Scrittore", icon: "pencil.and.outline", prompt: "Sei uno scrittore creativo con uno stile ricco e scorrevole."),
        AIRole(name: "Traduttore", icon: "character.bubble", prompt: "Sei un traduttore professionista. Traduci fedelmente mantenendo tono e sfumature."),
        AIRole(name: "Esperto marketing", icon: "megaphone", prompt: "Sei un esperto di marketing digitale e strategie di crescita."),
        AIRole(name: "Copywriter SEO", icon: "magnifyingglass", prompt: "Sei un copywriter SEO. Scrivi testi ottimizzati, chiari e persuasivi."),
        AIRole(name: "Analista dati", icon: "chart.bar", prompt: "Sei un analista di dati. Ragiona con numeri, tabelle e conclusioni verificabili."),
        AIRole(name: "Consulente finanziario", icon: "eurosign.circle", prompt: "Fornisci informazioni finanziarie chiare e bilanciate, ricordando che non sono consulenza personalizzata."),
        AIRole(name: "Coach", icon: "figure.run", prompt: "Sei un coach motivazionale pratico e incoraggiante."),
        AIRole(name: "Personal trainer", icon: "dumbbell", prompt: "Sei un personal trainer. Dai consigli di allenamento sicuri e progressivi."),
        AIRole(name: "Chef", icon: "fork.knife", prompt: "Sei uno chef. Proponi ricette chiare con dosi, tempi e consigli."),
        AIRole(name: "Viaggiatore", icon: "airplane", prompt: "Sei un esperto di viaggi. Suggerisci itinerari, consigli pratici e curiosità locali."),
        AIRole(name: "Storico", icon: "building.columns", prompt: "Sei uno storico. Contestualizza gli eventi con precisione."),
        AIRole(name: "Scienziato", icon: "atom", prompt: "Sei uno scienziato. Spiega con rigore e cita il consenso scientifico."),
        AIRole(name: "Filosofo", icon: "brain", prompt: "Sei un filosofo. Esplora le domande da più prospettive."),
        AIRole(name: "Poeta", icon: "text.quote", prompt: "Sei un poeta. Rispondi con eleganza e immagini evocative."),
        AIRole(name: "Comico", icon: "face.smiling", prompt: "Sei un comico. Rispondi con umorismo leggero e intelligente."),
        AIRole(name: "Designer", icon: "paintpalette", prompt: "Sei un designer UI/UX. Dai consigli visivi concreti e moderni."),
        AIRole(name: "Recruiter", icon: "person.text.rectangle", prompt: "Sei un recruiter. Aiuta con CV, lettere di presentazione e colloqui."),
        AIRole(name: "Revisore", icon: "checkmark.seal", prompt: "Sei un revisore attento. Correggi grammatica, stile e chiarezza."),
        AIRole(name: "Amico", icon: "heart", prompt: "Sei un amico empatico e alla mano.")
    ]

    static func named(_ name: String) -> AIRole {
        all.first { $0.name == name } ?? all[0]
    }
}

enum AIPersonaName {
    static let all = ["Nessuno", "Aria", "Luna", "Kai", "Nova", "Leo", "Mia", "Zoe", "Max", "Sage", "Iris", "Orion"]
}

enum ReplyLength: String, CaseIterable, Identifiable, Codable {
    case short = "Breve"
    case balanced = "Bilanciata"
    case detailed = "Dettagliata"
    var id: String { rawValue }

    var instruction: String {
        switch self {
        case .short: return "Rispondi in modo breve e diretto."
        case .balanced: return ""
        case .detailed: return "Rispondi in modo dettagliato e approfondito."
        }
    }
}

enum ReplyFormat: String, CaseIterable, Identifiable, Codable {
    case paragraphs = "Paragrafi"
    case bullets = "Elenco puntato"
    case steps = "Passo dopo passo"
    case mixed = "Misto"
    var id: String { rawValue }

    var instruction: String {
        switch self {
        case .paragraphs: return "Usa paragrafi in prosa."
        case .bullets: return "Struttura la risposta con elenchi puntati."
        case .steps: return "Struttura la risposta come passaggi numerati."
        case .mixed: return ""
        }
    }
}

enum ReplyLanguage {
    static let all = ["Automatica", "Italiano", "English", "Español", "Français", "Deutsch", "Português", "Nederlands", "Русский", "العربية", "中文", "日本語", "한국어"]
}

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system = "Sistema"
    case light = "Chiaro"
    case dark = "Scuro"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Provider API

enum APIProvider: String, CaseIterable, Identifiable, Codable {
    case openRouter = "OpenRouter"
    case openAI = "OpenAI"
    case groq = "Groq"
    case custom = "Personalizzato"
    var id: String { rawValue }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .custom: return ""
        }
    }

    var keyHint: String {
        switch self {
        case .openRouter: return "sk-or-…"
        case .openAI: return "sk-…"
        case .groq: return "gsk_…"
        case .custom: return "API key"
        }
    }
}

// MARK: - Suggerimenti iniziali ("@ Skills")

struct PromptSuggestion: Identifiable, Hashable {
    let title: String
    let subtitle: String
    let icon: String
    let prompt: String
    var id: String { title }

    static let all: [PromptSuggestion] = [
        PromptSuggestion(title: "Crea un sito web", subtitle: "landing page in HTML", icon: "globe", prompt: "Crea una landing page moderna in un unico file HTML con CSS per "),
        PromptSuggestion(title: "Budget mensile", subtitle: "tabella entrate/uscite", icon: "tablecells", prompt: "Crea un budget mensile in tabella per "),
        PromptSuggestion(title: "Lettera di presentazione", subtitle: "per un colloquio", icon: "envelope", prompt: "Scrivi una lettera di presentazione per il ruolo di "),
        PromptSuggestion(title: "Articolo SEO", subtitle: "ottimizzato e strutturato", icon: "doc.text.magnifyingglass", prompt: "Scrivi un articolo SEO di circa 800 parole su "),
        PromptSuggestion(title: "Scrivi un eBook", subtitle: "indice e primo capitolo", icon: "book", prompt: "Crea l'indice e il primo capitolo di un eBook su "),
        PromptSuggestion(title: "Spiegami", subtitle: "un concetto in modo semplice", icon: "lightbulb", prompt: "Spiegami in modo semplice ")
    ]
}
