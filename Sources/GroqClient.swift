import Foundation

enum GroqError: LocalizedError {
    case http(status: Int, message: String)
    case emptyResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case let .http(status, message):
            switch status {
            case 401: return "Invalid API key (401). \(message)"
            case 429: return "Rate limited (429). \(message)"
            default:  return "HTTP \(status): \(message)"
            }
        case .emptyResponse:
            return "Groq returned an empty response."
        case let .network(message):
            return "Network error: \(message)"
        }
    }
}

/// Minimal client for Groq's OpenAI-compatible chat completions endpoint.
struct GroqClient {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    private struct Message: Codable {
        let role: String
        let content: String
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
    }

    private struct ResponseBody: Decodable {
        struct Choice: Decodable { let message: Message }
        let choices: [Choice]
    }

    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }

    /// Sends `prompt` to Groq. `completion` is always called on the main queue.
    func complete(prompt: String,
                  systemPrompt: String?,
                  model: String,
                  apiKey: String,
                  completion: @escaping (Result<String, Error>) -> Void) {
        var messages: [Message] = []
        if let systemPrompt, !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(Message(role: "system", content: systemPrompt))
        }
        messages.append(Message(role: "user", content: prompt))

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages))
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<String, Error>
            defer { DispatchQueue.main.async { completion(result) } }

            if let error {
                result = .failure(GroqError.network(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                result = .failure(GroqError.emptyResponse)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
                    ?? String(data: data, encoding: .utf8)
                    ?? ""
                result = .failure(GroqError.http(status: http.statusCode, message: message))
                return
            }
            do {
                let body = try JSONDecoder().decode(ResponseBody.self, from: data)
                let text = body.choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result = text.isEmpty ? .failure(GroqError.emptyResponse) : .success(text)
            } catch {
                result = .failure(error)
            }
        }.resume()
    }
}
