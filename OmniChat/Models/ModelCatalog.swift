import Foundation

/// Modelli predefiniti, allineati alla lista del selettore di aifreeforever.com.
/// Gli ID seguono il formato OpenRouter. Se un ID cambia o non esiste,
/// apri il selettore modelli → "Tutti i modelli" per scegliere quello corretto
/// dall'elenco live del provider e aggiungerlo ai preferiti.
enum ModelCatalog {
    static let defaults: [AIModel] = [
        AIModel(id: "openai/gpt-5", name: "GPT 5"),
        AIModel(id: "deepseek/deepseek-v4-flash", name: "DeepSeek V4 Flash"),
        AIModel(id: "moonshotai/kimi-k2.6", name: "Kimi K2.6"),
        AIModel(id: "openai/gpt-5-mini", name: "GPT 5 Mini"),
        AIModel(id: "deepseek/deepseek-v3.2", name: "DeepSeek V3.2"),
        AIModel(id: "openai/gpt-5.4", name: "GPT 5.4"),
        AIModel(id: "openai/gpt-5.4-mini", name: "GPT 5.4 mini"),
        AIModel(id: "google/gemini-3.1-pro-preview", name: "Gemini 3.1"),
        AIModel(id: "x-ai/grok-4", name: "Grok 4"),
        AIModel(id: "qwen/qwen3.7", name: "Qwen 3.7"),
        AIModel(id: "meta-llama/llama-3.1-70b-instruct", name: "Llama 3.1"),
        AIModel(id: "microsoft/phi-4", name: "Phi 4"),
        AIModel(id: "openai/gpt-5-nano", name: "GPT 5 nano"),
        AIModel(id: "openai/gpt-4.1", name: "GPT 4.1"),
        AIModel(id: "openai/gpt-oss-120b", name: "GPT OSS (120b)"),
        AIModel(id: "google/gemini-3-pro-preview", name: "Gemini 3"),
        AIModel(id: "anthropic/claude-haiku-4.5", name: "Claude Haiku 4.5"),
        AIModel(id: "z-ai/glm-5.2", name: "GLM 5.2"),
        AIModel(id: "qwen/qwen3.6", name: "Qwen 3.6"),
        AIModel(id: "qwen/qwen3.5", name: "Qwen 3.5"),
        AIModel(id: "anthropic/claude-sonnet-4.6", name: "Claude Sonnet 4.6"),
        AIModel(id: "google/gemini-3.5-flash", name: "Gemini 3.5 Flash"),
        AIModel(id: "anthropic/claude-opus-5.5", name: "Claude Opus 5.5"),
        AIModel(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5")
    ]

    static let defaultModelID = "openai/gpt-5"
}
