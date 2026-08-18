import Foundation

/// Minimal async client for a local Ollama server. Sendable so it can cross actors.
struct OllamaClient: Sendable {
    var host: String
    var model: String

    private var generateURL: URL? { URL(string: host)?.appendingPathComponent("api/generate") }
    private var tagsURL: URL? { URL(string: host)?.appendingPathComponent("api/tags") }

    /// Returns true if the server answers /api/tags.
    func ping() async -> Bool {
        guard let url = tagsURL else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// One-shot generation with thinking disabled. `imageBase64` triggers vision.
    func generate(prompt: String, imageBase64: String? = nil,
                  timeout: TimeInterval = 300) async throws -> String {
        guard let url = generateURL else { throw OllamaError.badHost }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "think": false,
            "options": ["temperature": 0.2],
        ]
        if let img = imageBase64 { body["images"] = [img] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (obj?["response"] as? String) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum OllamaError: Error, CustomStringConvertible {
    case badHost
    case badStatus(Int)
    var description: String {
        switch self {
        case .badHost: return "invalid Ollama host"
        case .badStatus(let c): return "Ollama HTTP \(c)"
        }
    }
}
