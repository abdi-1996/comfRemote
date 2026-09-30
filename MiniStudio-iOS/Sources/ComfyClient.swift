import Foundation
import Network

enum ComfyClientError: LocalizedError {
    case badURL
    case badResponse
    case server(String)
    case missingPromptID
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Неверный адрес ComfyUI"
        case .badResponse:
            return "ComfyUI вернул непонятный ответ"
        case .server(let text):
            return text
        case .missingPromptID:
            return "ComfyUI не вернул prompt_id"
        case .network(let text):
            return text
        }
    }
}

struct ComfyCheckResult: Sendable {
    let online: Bool
    let message: String
    let normalizedURL: String?
}

private struct RawHTTPResponse {
    let statusCode: Int
    let body: Data
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
                message: "Неверный адрес. Пример: 192.168.1.25:8188 или 100.x.x.x:8188",
                normalizedURL: nil
            )
        }

        let normalized = root.absoluteString
        let endpoints = ["system_stats", ""]
        var errors: [String] = []

        for endpoint in endpoints {
            let url = endpoint.isEmpty ? root : root.appendingPathComponent(endpoint)

            do {
                let response = try await request(
                    url: url,
                    method: "GET",
                    headers: ["Accept": "application/json,text/html,*/*"],
                    body: nil,
                    timeout: 8
                )

                if (200..<500).contains(response.statusCode) {
                    return ComfyCheckResult(
                        online: true,
                        message: "Соединение установлено • HTTP \(response.statusCode)",
                        normalizedURL: normalized
                    )
                }

                errors.append("HTTP \(response.statusCode)")
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        let detail = errors.last ?? "Нет ответа от сервера"
        return ComfyCheckResult(
            online: false,
            message: detail + ". Проверь запуск ComfyUI с --listen 0.0.0.0 --port 8188.",
            normalizedURL: normalized
        )
    }

    static func queue(base: String, prompt: [String: Any]) async throws -> String {
        guard let root = normalizedBaseURL(base) else {
            throw ComfyClientError.badURL
        }

        let url = root.appendingPathComponent("prompt")
        let payload: [String: Any] = [
            "prompt": prompt,
            "client_id": UUID().uuidString
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let response = try await request(
            url: url,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json"
            ],
            body: body,
            timeout: 30
        )

        guard (200..<300).contains(response.statusCode) else {
            let text = String(data: response.body, encoding: .utf8) ?? "HTTP \(response.statusCode)"
            throw ComfyClientError.server(text)
        }

        guard let json = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let promptID = json["prompt_id"] as? String else {
            throw ComfyClientError.missingPromptID
        }

        return promptID
    }

    static func generationFinished(base: String, promptID: String) async throws -> Bool {
        guard let root = normalizedBaseURL(base) else {
            throw ComfyClientError.badURL
        }

        let url = root
            .appendingPathComponent("history")
            .appendingPathComponent(promptID)

        let response = try await request(
            url: url,
            method: "GET",
            headers: ["Accept": "application/json"],
            body: nil,
            timeout: 8
        )

        guard (200..<300).contains(response.statusCode) else {
            return false
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            return false
        }

        return json[promptID] != nil
    }

    static func uploadInput(
        base: String,
        data: Data,
        fileName: String,
        mimeType: String
    ) async throws -> String {
        guard let root = normalizedBaseURL(base) else {
            throw ComfyClientError.badURL
        }

        let boundary = "ComfyMobileBoundary-" + UUID().uuidString
        var body = Data()

        func append(_ string: String) {
            if let chunk = string.data(using: .utf8) {
                body.append(chunk)
            }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"image\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"type\"\r\n\r\n")
        append("input\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"overwrite\"\r\n\r\n")
        append("true\r\n")

        append("--\(boundary)--\r\n")

        let endpoints = ["upload/image", "api/upload/image"]
        var lastError = "Не удалось загрузить материал"

        for endpoint in endpoints {
            let url = root.appendingPathComponent(endpoint)
            let response = try await request(
                url: url,
                method: "POST",
                headers: [
                    "Content-Type": "multipart/form-data; boundary=\(boundary)",
                    "Accept": "application/json"
                ],
                body: body,
                timeout: 120
            )

            if (200..<300).contains(response.statusCode) {
                guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                      let name = json["name"] as? String else {
                    return fileName
                }

                let subfolder = json["subfolder"] as? String ?? ""
                return subfolder.isEmpty ? name : subfolder + "/" + name
            }

            lastError = String(data: response.body, encoding: .utf8)
                ?? "HTTP \(response.statusCode)"

            if response.statusCode != 404 {
                break
            }
        }

        throw ComfyClientError.server(lastError)
    }

    private static func request(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> RawHTTPResponse {
        if url.scheme?.lowercased() == "http" {
            return try await rawHTTP(
                url: url,
                method: method,
                headers: headers,
                body: body,
                timeout: timeout
            )
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("ComfyMobile/1.0.4", forHTTPHeaderField: "User-Agent")

        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }

        req.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw ComfyClientError.badResponse
            }
            return RawHTTPResponse(statusCode: http.statusCode, body: data)
        } catch let error as URLError {
            throw ComfyClientError.network(readableNetworkError(error))
        }
    }

    private static func rawHTTP(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        timeout: TimeInterval
    ) async throws -> RawHTTPResponse {
        guard let hostString = url.host,
              let portValue = url.port ?? defaultPort(for: url),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(portValue)) else {
            throw ComfyClientError.badURL
        }

        let host = NWEndpoint.Host(hostString)
        let connection = NWConnection(host: host, port: nwPort, using: .tcp)

        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            path += "?" + query
        }

        var allHeaders = headers
        let defaultPortValue = defaultPort(for: url) ?? 80
        allHeaders["Host"] = portValue == defaultPortValue
            ? hostString
            : "\(hostString):\(portValue)"
        allHeaders["Connection"] = "close"
        allHeaders["User-Agent"] = "ComfyMobile/1.0.4"

        if let body {
            allHeaders["Content-Length"] = String(body.count)
        }

        var requestText = "\(method) \(path) HTTP/1.1\r\n"
        for key in allHeaders.keys.sorted() {
            if let value = allHeaders[key] {
                requestText += "\(key): \(value)\r\n"
            }
        }
        requestText += "\r\n"

        guard var requestData = requestText.data(using: .utf8) else {
            throw ComfyClientError.badRequestFallback
        }

        if let body {
            requestData.append(body)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var finished = false
            var received = Data()

            func finish(_ result: Result<RawHTTPResponse, Error>) {
                lock.lock()
                defer { lock.unlock() }

                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(with: result)
            }

            func tryComplete(isStreamComplete: Bool) -> Bool {
                do {
                    if let parsed = try parseHTTPResponse(
                        received,
                        streamComplete: isStreamComplete
                    ) {
                        finish(.success(parsed))
                        return true
                    }
                } catch {
                    finish(.failure(error))
                    return true
                }

                return false
            }

            func receiveNext() {
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: 1_048_576
                ) { data, _, isComplete, error in
                    if let data {
                        received.append(data)
                    }

                    if let error {
                        finish(
                            .failure(
                                ComfyClientError.network(networkMessage(error))
                            )
                        )
                        return
                    }

                    if tryComplete(isStreamComplete: isComplete) {
                        return
                    }

                    if isComplete {
                        finish(.failure(ComfyClientError.badResponse))
                        return
                    }

                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: requestData,
                        completion: .contentProcessed { error in
                            if let error {
                                finish(
                                    .failure(
                                        ComfyClientError.network(networkMessage(error))
                                    )
                                )
                            } else {
                                receiveNext()
                            }
                        }
                    )

                case .failed(let error):
                    finish(
                        .failure(
                            ComfyClientError.network(networkMessage(error))
                        )
                    )

                case .cancelled:
                    break

                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue.global(qos: .userInitiated))

            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + timeout) {
                    finish(
                        .failure(
                            ComfyClientError.network(
                                "Тайм-аут: iPhone не получил ответ от ComfyUI"
                            )
                        )
                    )
                }
        }
    }

    private static func parseHTTPResponse(
        _ data: Data,
        streamComplete: Bool
    ) throws -> RawHTTPResponse? {
        let separator = Data([13, 10, 13, 10])

        guard let headerRange = data.range(of: separator) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)

        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw ComfyClientError.badResponse
        }

        let lines = headerText.components(separatedBy: "\r\n")

        guard let statusLine = lines.first else {
            throw ComfyClientError.badResponse
        }

        let statusParts = statusLine.split(separator: " ")

        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw ComfyClientError.badResponse
        }

        var parsedHeaders: [String: String] = [:]

        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }

            let key = line[..<colon]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()

            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            parsedHeaders[key] = value
        }

        let bodyStart = headerRange.upperBound
        let rawBody = data.subdata(in: bodyStart..<data.count)

        if let lengthText = parsedHeaders["content-length"],
           let length = Int(lengthText) {
            guard rawBody.count >= length else { return nil }

            return RawHTTPResponse(
                statusCode: statusCode,
                body: Data(rawBody.prefix(length))
            )
        }

        if parsedHeaders["transfer-encoding"]?
            .lowercased()
            .contains("chunked") == true {

            if let decoded = decodeChunkedBody(rawBody) {
                return RawHTTPResponse(
                    statusCode: statusCode,
                    body: decoded
                )
            }

            return streamComplete
                ? RawHTTPResponse(statusCode: statusCode, body: rawBody)
                : nil
        }

        if streamComplete {
            return RawHTTPResponse(
                statusCode: statusCode,
                body: rawBody
            )
        }

        return nil
    }

    private static func decodeChunkedBody(_ data: Data) -> Data? {
        var cursor = data.startIndex
        var output = Data()
        let crlf = Data([13, 10])

        while cursor < data.endIndex {
            guard let lineEnd = data.range(
                of: crlf,
                options: [],
                in: cursor..<data.endIndex
            ) else {
                return nil
            }

            let lineData = data.subdata(in: cursor..<lineEnd.lowerBound)

            guard let line = String(data: lineData, encoding: .utf8) else {
                return nil
            }

            let sizeText = line
                .split(separator: ";", maxSplits: 1)
                .first
                .map(String.init) ?? line

            guard let size = Int(
                sizeText.trimmingCharacters(in: .whitespacesAndNewlines),
                radix: 16
            ) else {
                return nil
            }

            cursor = lineEnd.upperBound

            if size == 0 {
                return output
            }

            guard data.distance(from: cursor, to: data.endIndex) >= size + 2 else {
                return nil
            }

            let chunkEnd = data.index(cursor, offsetBy: size)
            output.append(data.subdata(in: cursor..<chunkEnd))

            let suffixEnd = data.index(chunkEnd, offsetBy: 2)

            guard data.subdata(in: chunkEnd..<suffixEnd) == crlf else {
                return nil
            }

            cursor = suffixEnd
        }

        return nil
    }

    private static func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func networkMessage(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED:
                return "Подключение отклонено. Проверь, что ComfyUI запущен и слушает порт 8188."
            case .ETIMEDOUT:
                return "Тайм-аут подключения к ComfyUI."
            case .ENETUNREACH, .EHOSTUNREACH:
                return "Компьютер с ComfyUI недоступен по сети."
            default:
                return "Ошибка сети: \(code.rawValue)"
            }

        case .dns:
            return "Не удалось найти адрес ComfyUI."

        case .tls:
            return "Ошибка TLS-соединения."

        @unknown default:
            return "Не удалось подключиться к ComfyUI."
        }
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
        case .networkConnectionLost:
            return "Соединение было потеряно"
        default:
            return error.localizedDescription
        }
    }
}

private extension ComfyClientError {
    static var badRequestFallback: ComfyClientError {
        .network("Не удалось сформировать HTTP-запрос")
    }
}
