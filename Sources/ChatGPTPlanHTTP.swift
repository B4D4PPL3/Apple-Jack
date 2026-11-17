import Foundation

protocol ChatGPTHTTPClient {
    func data(_ url: URL, form: [String: String]?, token: String?) async throws -> Data
    func discovery() async throws -> [String: Any]
    func publishedKeys() async throws -> [[String: Any]]
    func reply(input: String, model: String, token: String) async throws -> ChatGPTPlanReply
}
extension ChatGPTHTTPClient {
    func data(_ url: URL, form: [String: String]) async throws -> Data { try await data(url, form: form, token: nil) }
    func data(_ url: URL, token: String) async throws -> Data { try await data(url, form: nil, token: token) }
}
// Refuse redirects so bearer credentials cannot be forwarded to another host.
final class ChatGPTPlanHTTP: NSObject, ChatGPTHTTPClient, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 180
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func data(_ url: URL, form: [String: String]? = nil, token: String? = nil) async throws -> Data {
        guard Self.allowed(url) else { throw ChatGPTConnectionError.invalidSignIn }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.httpMethod = "POST"; request.httpBody = ChatGPTSignInProtocol.form(form)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ChatGPTConnectionError("ChatGPT returned an unreadable response.") }
        guard (200..<300).contains(response.statusCode) else {
            throw ChatGPTConnectionError.server(data, status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id"))
        }
        guard data.count <= 4_000_000 else { throw ChatGPTConnectionError("ChatGPT returned too much information. Please try again.") }
        return data
    }
    static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && ["auth.openai.com", "api.openai.com"].contains(url.host ?? "")
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil && url.fragment == nil
    }
    func discovery() async throws -> [String: Any] {
        let data = try await data(URL(string: ChatGPTSignInProtocol.issuer + "/.well-known/openid-configuration")!)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["issuer"] as? String == ChatGPTSignInProtocol.issuer else {
            throw ChatGPTConnectionError.invalidSignIn
        }
        return object
    }
    func publishedKeys() async throws -> [[String: Any]] {
        let discovery = try await discovery()
        guard let value = discovery["jwks_uri"] as? String, let url = URL(string: value),
              Self.allowed(url), url.host == "auth.openai.com" else { throw ChatGPTConnectionError.invalidSignIn }
        let data = try await data(url)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let keys = root["keys"] as? [[String: Any]] else { throw ChatGPTConnectionError.invalidSignIn }
        return keys
    }
    static func request(input: String, model: String, token: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: ChatGPTSignInProtocol.resource + "/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true,
            "instructions": "You are Apple Jack, a concise desktop companion. Reply in plain text for a speech bubble. Use the conversation context Jack supplies. Jack handles desktop actions separately; do not claim you performed an action you cannot perform.",
            "input": [["role": "user", "content": input]]
        ])
        return request
    }
    func reply(input: String, model: String, token: String) async throws -> ChatGPTPlanReply {
        let request = try Self.request(input: input, model: model, token: token)
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse else { throw ChatGPTConnectionError("ChatGPT returned an unreadable response.") }
        guard response.statusCode == 200 else {
            var errorData = Data()
            for try await byte in bytes { errorData.append(byte); if errorData.count >= 64_000 { break } }
            throw ChatGPTConnectionError.server(errorData, status: response.statusCode, requestID: response.value(forHTTPHeaderField: "x-request-id"))
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if !contentType.hasPrefix("text/event-stream") {
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                body.append(byte)
                guard body.count <= 8_000_000 else { throw ChatGPTConnectionError("ChatGPT’s reply was too large. Try a shorter request.") }
            }
            return try Self.nonStreamReply(body, contentType: contentType)
        }
        var parser = ChatGPTResponseStream(), line = Data()
        for try await byte in bytes {
            if byte == 10 {
                try Task.checkCancellation()
                if line.last == 13 { line.removeLast() }
                guard let text = String(data: line, encoding: .utf8) else { throw ChatGPTConnectionError("ChatGPT returned unreadable text.") }
                try parser.line(text); line.removeAll(keepingCapacity: true)
                if parser.reply != nil { return try parser.finish() }
            } else {
                line.append(byte)
                guard line.count < 4_000_000 else { throw ChatGPTConnectionError("ChatGPT’s reply was too large. Try a shorter request.") }
            }
        }
        if !line.isEmpty, let text = String(data: line, encoding: .utf8) { try parser.line(text) }
        return try parser.finish()
    }
    // Some successful Responses requests are delivered as one JSON response.
    // Accept only the canonical completed response (never an arbitrary JSON
    // message or a partial result), while continuing to request streaming.
    static func nonStreamReply(_ data: Data, contentType: String) throws -> ChatGPTPlanReply {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if root["error"] != nil, !(root["error"] is NSNull) {
                throw ChatGPTConnectionError.server(data, status: 0)
            }
            if root["object"] as? String == "response" {
                guard root["status"] as? String == "completed" else {
                    throw ChatGPTConnectionError("ChatGPT’s reply ended before it finished. Your request was not retried automatically. You can try again.")
                }
                var parser = ChatGPTResponseStream()
                let frame = try JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": root])
                try parser.line("data: " + String(decoding: frame, as: UTF8.self))
                return try parser.finish()
            }
        }
        // Be tolerant of an SSE body whose response header is missing/wrong.
        // The normal parser still requires its explicit completed terminal event.
        if let text = String(data: data, encoding: .utf8), text.hasPrefix("data:") || text.hasPrefix("event:") || text.hasPrefix(":") {
            var parser = ChatGPTResponseStream()
            for line in text.components(separatedBy: "\n") { try parser.line(line.hasSuffix("\r") ? String(line.dropLast()) : line) }
            return try parser.finish()
        }
        let format = contentType.hasPrefix("application/json") ? "JSON" : contentType.hasPrefix("text/html") ? "a web page" : "an unexpected format"
        throw ChatGPTConnectionError("ChatGPT returned \(format) without a completed answer. Please try again later.")
    }
}
