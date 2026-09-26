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

struct ComfyCheckResult: Sendable {
    let online: Bool
    let message: String
    let normalizedURL: String?
}

struct ComfyClient {
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }

        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil else { return nil }

        if components.port == nil {
            components.port = 8188
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func check(base: String) async -> ComfyCheckResult {
        guard let root = normalizedBaseURL(base) else {
            return ComfyCheckResult(
                online: false,
                message: "Неверный адрес. Пример: http://192.168.1.25:8188 или http://100.x.x.x:8188",
                normalizedURL: nil
            )
        }

        let normalized = root.absoluteString
        let endpoints = ["system_stats", ""]
        var errors: [String] = []

        for endpoint in endpoints {
            let url = endpoint.isEmpty ? root : root.appendingPathComponent(endpoint)
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8
            request.setValue("ComfyMobile/1.0.1", forHTTPHeaderField: "User-Agent")

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if (200..<500).contains(http.statusCode) {
                        return ComfyCheckResult(
                            online: true,
                            message: "Соединение установлено • HTTP \(http.statusCode)",
                            normalizedURL: normalized
                        )
                    }
                    errors.append("HTTP \(http.statusCode)")
                } else {
                    errors.append("Нет HTTP-ответа")
                }
            } catch let error as URLError {
                errors.append(readableNetworkError(error))
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        let detail = errors.last ?? "Нет ответа от сервера"
        return ComfyCheckResult(
            online: false,
            message: detail + ". Проверь, что ComfyUI запущен с --listen 0.0.0.0 и порт 8188 доступен.",
            normalizedURL: normalized
        )
    }

    static func queue(base: String, prompt: [String: Any]) async throws -> String {
        guard let root = normalizedBaseURL(base) else { throw ComfyClientError.badURL }
        let url = root.appendingPathComponent("prompt")

        let body: [String: Any] = [
            "prompt": prompt,
            "client_id": UUID().uuidString
        ]
        let data = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("ComfyMobile/1.0.1", forHTTPHeaderField: "User-Agent")
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

    private static func readableNetworkError(_ error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "Тайм-аут: iPhone не получил ответ"
        case .cannotConnectToHost:
            return "Не удалось подключиться к ComfyUI"
        case .cannotFindHost:
            return "Адрес компьютера не найден"
        case .notConnectedToInternet:
            return "На iPhone нет сетевого подключения"
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS заблокировал HTTP-соединение"
        case .networkConnectionLost:
            return "Соединение было потеряно"
        default:
            return error.localizedDescription
        }
    }
}
