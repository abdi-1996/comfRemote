import Foundation

enum ComfyClientError: LocalizedError {
    case badURL
    case badResponse
    case server(String)
    case missingPromptID

    var errorDescription: String? {
        switch self {
        case .badURL: return "Неверный адрес ComfyUI"
        case .badResponse: return "ComfyUI вернул непонятный ответ"
        case .server(let text): return text
        case .missingPromptID: return "ComfyUI не вернул prompt_id"
        }
    }
}

struct ComfyClient {
    static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed), u.scheme != nil { return u }
        return URL(string: "http://" + trimmed)
    }

    static func check(base: String) async -> Bool {
        guard let root = normalizedBaseURL(base),
              let url = URL(string: "system_stats", relativeTo: root.appendingPathComponent("/")) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    static func queue(base: String, prompt: [String: Any]) async throws -> String {
        guard let root = normalizedBaseURL(base),
              let url = URL(string: "prompt", relativeTo: root.appendingPathComponent("/")) else { throw ComfyClientError.badURL }

        let body: [String: Any] = [
            "prompt": prompt,
            "client_id": UUID().uuidString
        ]
        let data = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ComfyClientError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: responseData, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw ComfyClientError.server(text)
        }
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let promptID = json["prompt_id"] as? String else { throw ComfyClientError.missingPromptID }
        return promptID
    }
}
