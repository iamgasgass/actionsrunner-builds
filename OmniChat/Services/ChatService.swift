import Foundation

enum ChatServiceError: LocalizedError {
    case invalidURL
    case missingKey
    case http(Int, String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "L'URL del provider non è valido. Controllalo nelle Impostazioni."
        case .missingKey:
            return "Aggiungi la tua API key nelle Impostazioni per iniziare a chattare."
        case .http(let code, let body):
            let message = ChatServiceError.extractMessage(from: body) ?? body
            switch code {
            case 401: return "API key non valida (401). \(message)"
            case 402: return "Credito insufficiente sul provider (402). \(message)"
            case 404: return "Modello non trovato (404). Scegline un altro dal selettore. \(message)"
            case 429: return "Troppe richieste (429). Riprova tra poco. \(message)"
            default: return "Errore \(code): \(message)"
            }
        case .server(let message):
            return message
        }
    }

    static func extractMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let msg = error["message"] as? String { return msg }
        if let msg = json["message"] as? String { return msg }
        return nil
    }
}

/// Client per qualsiasi API compatibile con OpenAI Chat Completions (OpenRouter, OpenAI, Groq, server locali…).
struct ChatService {
    var baseURL: String
    var apiKey: String

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        struct APIError: Decodable { let message: String? }
        let choices: [Choice]?
        let error: APIError?
    }

    private func endpoint(_ path: String) throws -> URL {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/" + path), url.scheme?.hasPrefix("http") == true else {
            throw ChatServiceError.invalidURL
        }
        return url
    }

    private func applyHeaders(_ request: inout URLRequest) {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header opzionali usati da OpenRouter per identificare l'app
        request.setValue("https://github.com/omnichat-ios", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("OmniChat iOS", forHTTPHeaderField: "X-Title")
    }

    /// Converte la cronologia nel formato messaggi dell'API, incluse le immagini.
    static func apiMessages(system: String, history: [ChatMessage]) -> [[String: Any]] {
        var result: [[String: Any]] = [["role": "system", "content": system]]
        for message in history where !message.isError {
            if message.role == .assistant && message.content.isEmpty { continue }
            if let image = message.imageData {
                var parts: [[String: Any]] = []
                if !message.content.isEmpty {
                    parts.append(["type": "text", "text": message.content])
                }
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(image.base64EncodedString())"]
                ])
                result.append(["role": message.role.rawValue, "content": parts])
            } else {
                result.append(["role": message.role.rawValue, "content": message.content])
            }
        }
        return result
    }

    /// Invia la richiesta in streaming (SSE) e restituisce i frammenti di testo man mano.
    func stream(model: String, messages: [[String: Any]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
                        throw ChatServiceError.missingKey
                    }
                    var request = URLRequest(url: try endpoint("chat/completions"))
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    applyHeaders(&request)
                    let body: [String: Any] = ["model": model, "messages": messages, "stream": true]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ChatServiceError.server("Risposta non valida dal server.")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw ChatServiceError.http(http.statusCode, String(decoding: data, as: UTF8.self))
                    }

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else { continue }
                        if let message = chunk.error?.message {
                            throw ChatServiceError.server(message)
                        }
                        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scarica l'elenco live dei modelli dal provider (GET /models).
    func fetchModels() async throws -> [AIModel] {
        var request = URLRequest(url: try endpoint("models"))
        applyHeaders(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatServiceError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        struct ModelList: Decodable {
            struct Item: Decodable { let id: String; let name: String? }
            let data: [Item]
        }
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return list.data
            .map { item in
                // OpenRouter restituisce nomi tipo "OpenAI: GPT-5": teniamo la parte dopo i due punti
                let raw = item.name ?? item.id
                let name = raw.split(separator: ":", maxSplits: 1).last
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? raw
                return AIModel(id: item.id, name: name)
            }
            .sorted { $0.provider == $1.provider ? $0.name < $1.name : $0.provider < $1.provider }
    }
}
