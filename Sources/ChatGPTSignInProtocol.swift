import Foundation
import CryptoKit
import Security

// The public Sign in with ChatGPT contract. No ChatGPT cookies, private
// endpoints, or credentials from the ChatGPT/Codex applications are used.
enum ChatGPTSignInProtocol {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planScope = "chatgpt.tokens.use.direct"
    static let usageURL = URL(string: "https://chatgpt.com/settings/usage")!
    static let callbackPath = "/auth/callback"

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode64(_ string: String) -> Data? {
        guard string.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ChatGPTConnectionError("Couldn’t prepare secure sign-in. Please try again.")
        }
        return base64URL(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    static func authorize(host: String, callback: URL, state: String, nonce: String, verifier: String,
                          clientID: String?, email: String?, askConsent: Bool) -> URL {
        var values = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": host,
                      "response_type": "code", "redirect_uri": callback.absoluteString, "scope": scopes,
                      "resource": resource, "state": state, "nonce": nonce, "code_challenge_method": "S256",
                      "code_challenge": challenge(verifier)]
        if clientID == nil { values["agent_name_hint"] = "Apple Jack" }
        if let email, !email.isEmpty { values["login_hint"] = email }
        if askConsent { values["prompt"] = "consent" }
        var url = URLComponents(string: issuer + "/api/accounts/authorize")!
        url.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    struct Callback {
        let code: String
        let clientID: String
    }
    static func callback(_ url: URL, expectedURL: URL, state: String, clientID: String?) throws -> Callback {
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == expectedURL.port,
              url.path == callbackPath, url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ChatGPTConnectionError.invalidSignIn }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw ChatGPTConnectionError.invalidSignIn }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let returnedState = values["state"], equal(returnedState, state) else { throw ChatGPTConnectionError.invalidSignIn }
        if values["error"] != nil {
            throw ChatGPTConnectionError(values["error"] == "access_denied" ? "Sign-in was canceled. Your current assistant is still available." : "OpenAI couldn’t complete sign-in. Please try again.")
        }
        guard let code = values["code"], !code.isEmpty, code.count < 8192 else { throw ChatGPTConnectionError.invalidSignIn }
        let returnedID = values["client_id"] ?? clientID ?? ""
        guard !returnedID.isEmpty, returnedID != "dynamic_agent_client", returnedID.count < 256,
              clientID == nil || returnedID == clientID else { throw ChatGPTConnectionError.invalidSignIn }
        return Callback(code: code, clientID: returnedID)
    }
    struct Identity { let issuer: String; let subject: String; let email: String }
    static func identity(_ jwt: String, keys: [[String: Any]], clientID: String, nonce: String?,
                         expectedSubject: String? = nil, now: Date = Date()) throws -> Identity {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, jwt.utf8.count < 64_000,
              let headerData = decode64(parts[0]), let payload = decode64(parts[1]), let signature = decode64(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let algorithm = header["alg"] as? String, ["RS256", "ES256"].contains(algorithm),
              header["crit"] == nil, let kid = header["kid"] as? String, !kid.isEmpty else { throw ChatGPTConnectionError.invalidSignIn }
        let matching = keys.filter { ($0["kid"] as? String) == kid && ($0["use"] == nil || ($0["use"] as? String) == "sig") && ($0["alg"] == nil || ($0["alg"] as? String) == algorithm) }
        guard matching.count == 1 else { throw ChatGPTConnectionError.invalidSignIn }
        let jwk = matching[0], message = Data((parts[0] + "." + parts[1]).utf8)
        var verified = false
        if algorithm == "RS256", jwk["kty"] as? String == "RSA",
           let n = (jwk["n"] as? String).flatMap(decode64), let e = (jwk["e"] as? String).flatMap(decode64), n.count >= 256 {
            let keyData = der(0x30, derInteger(n) + derInteger(e))
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
            if let key = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, nil) {
                verified = SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
            }
        } else if algorithm == "ES256", jwk["kty"] as? String == "EC", jwk["crv"] as? String == "P-256",
                  let x = (jwk["x"] as? String).flatMap(decode64), let y = (jwk["y"] as? String).flatMap(decode64), x.count == 32, y.count == 32,
                  let key = try? P256.Signing.PublicKey(x963Representation: Data([4]) + x + y),
                  let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) {
            verified = key.isValidSignature(sig, for: message)
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard verified, claims["iss"] as? String == issuer, audiences.contains(clientID),
              (audiences.count == 1 && claims["azp"] == nil) || claims["azp"] as? String == clientID,
              let expires = claims["exp"] as? Double, expires > now.timeIntervalSince1970,
              let subject = claims["sub"] as? String, !subject.isEmpty,
              expectedSubject == nil || subject == expectedSubject else { throw ChatGPTConnectionError.invalidSignIn }
        if let nonce { guard let returned = claims["nonce"] as? String, equal(nonce, returned) else { throw ChatGPTConnectionError.invalidSignIn } }
        if let nbf = claims["nbf"] as? Double, nbf > now.timeIntervalSince1970 + 60 { throw ChatGPTConnectionError.invalidSignIn }
        if let iat = claims["iat"] as? Double, iat > now.timeIntervalSince1970 + 60 { throw ChatGPTConnectionError.invalidSignIn }
        return Identity(issuer: issuer, subject: subject, email: claims["email"] as? String ?? "ChatGPT account")
    }
    private static func derInteger(_ bytes: Data) -> Data {
        var b = bytes
        while b.count > 1 && b.first == 0 { b.removeFirst() }
        if (b.first ?? 0) & 0x80 != 0 { b.insert(0, at: b.startIndex) }
        return der(0x02, b)
    }
    private static func der(_ tag: UInt8, _ body: Data) -> Data {
        var count = body.count, size = [UInt8]()
        repeat { size.insert(UInt8(count & 255), at: 0); count >>= 8 } while count > 0
        let length = body.count < 128 ? [UInt8(body.count)] : [0x80 | UInt8(size.count)] + size
        return Data([tag] + length) + body
    }
}

struct ChatGPTConnectionError: LocalizedError {
    let message: String
    var code: String? = nil
    var status: Int? = nil
    var requestID: String? = nil
    var isUsageLimit: Bool { code == "subscription_sharing_usage_limit_exceeded" || status == 429 }
    var invalidRefresh: Bool { ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "") }
    var errorDescription: String? { message }
    init(_ message: String, code: String? = nil, status: Int? = nil, requestID: String? = nil) {
        self.message = message; self.code = code; self.status = status; self.requestID = requestID
    }
    static let invalidSignIn = ChatGPTConnectionError("The sign-in reply couldn’t be verified. Please start sign-in again from Jack.")
    static let signedOut = ChatGPTConnectionError("Connect your ChatGPT account in Menu → AI Assistant → ChatGPT Connection, or choose ChatGPT (Shortcuts).")
    static let noPermission = ChatGPTConnectionError("You’re signed in, but ChatGPT plan use isn’t enabled. Open ChatGPT Connection to enable it, or choose ChatGPT (Shortcuts).")
    static func server(_ data: Data, status: Int, requestID: String? = nil) -> ChatGPTConnectionError {
        let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let error = root["error"] as? [String: Any] ?? root
        let code = (error["code"] as? String) ?? (root["error"] as? String)
        let message: String
        if code == "subscription_sharing_usage_limit_exceeded" || status == 429 {
            message = "Your ChatGPT plan or Apple Jack’s usage limit has been reached. Choose Manage Usage to review it."
        } else if code == "subscription_sharing_user_not_eligible" {
            message = "This ChatGPT account or workspace isn’t eligible to use its plan in Jack. You can still choose ChatGPT (Shortcuts)."
        } else if status == 401 || ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].contains(code ?? "") {
            message = "ChatGPT couldn’t authorize this connection. Open ChatGPT Connection and sign in again."
        } else if status == 403 {
            message = "OpenAI hasn’t allowed this request for your account, workspace, or region. Check your ChatGPT connection and plan permissions."
        } else if status >= 500 {
            message = "ChatGPT is temporarily unavailable. Please try again later; your connection has been kept."
        } else {
            message = "ChatGPT couldn’t complete this request. Check your connection and selected model, then try again."
        }
        return ChatGPTConnectionError(message, code: code, status: status, requestID: requestID)
    }
}

struct ChatGPTPlanModel: Equatable {
    let slug: String
    let name: String
    static func catalog(_ data: Data) throws -> [ChatGPTPlanModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["models"] as? [[String: Any]] else {
            throw ChatGPTConnectionError("ChatGPT’s model list couldn’t be read. Please refresh it.")
        }
        var seen = Set<String>()
        return items.compactMap { item in
            guard item["visibility"] as? String == "list", let slug = item["slug"] as? String, !slug.isEmpty,
                  let name = item["display_name"] as? String, !name.isEmpty, seen.insert(slug).inserted else { return nil }
            return ChatGPTPlanModel(slug: slug, name: name)
        }
    }
}

struct ChatGPTPlanReply { let text: String; let tokens: Int? }
// Parses SSE frames (including multi-line data), and never treats a partial or
// failed response as a completed answer. Usage is per reply, not plan remaining.
struct ChatGPTResponseStream {
    private var lines = [String]()
    private var size = 0
    private(set) var deltaText = ""
    private(set) var reply: ChatGPTPlanReply?
    mutating func line(_ line: String) throws {
        size += line.utf8.count
        guard size <= 8_000_000 else { throw ChatGPTConnectionError("ChatGPT’s reply was too large. Try a shorter request.") }
        if line.isEmpty { try frame(); return }
        if line.hasPrefix("data:") { lines.append(String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " "))) }
    }
    mutating func finish() throws -> ChatGPTPlanReply {
        try frame()
        guard let reply, !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatGPTConnectionError("ChatGPT’s reply ended before it finished. Your request was not retried automatically. You can try again.")
        }
        return reply
    }
    private mutating func frame() throws {
        guard !lines.isEmpty else { return }
        let string = lines.joined(separator: "\n"); lines.removeAll()
        guard string != "[DONE]" else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any],
              let type = object["type"] as? String else { throw ChatGPTConnectionError("ChatGPT returned an unreadable reply. Please try again.") }
        if type == "response.output_text.delta" { deltaText += object["delta"] as? String ?? "" }
        if type == "response.failed" || type == "error" {
            let envelope = object["response"] as? [String: Any] ?? object
            throw ChatGPTConnectionError.server(try JSONSerialization.data(withJSONObject: envelope), status: 0)
        }
        if type == "response.incomplete" { throw ChatGPTConnectionError("ChatGPT couldn’t finish this answer. Try a shorter request.") }
        if type == "response.completed" {
            guard let response = object["response"] as? [String: Any], response["status"] as? String == "completed" else {
                throw ChatGPTConnectionError("ChatGPT’s answer didn’t finish successfully.")
            }
            let content = (response["output"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "message" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .compactMap { item -> String? in
                    if item["type"] as? String == "output_text" { return item["text"] as? String }
                    if item["type"] as? String == "refusal" { return item["refusal"] as? String }
                    return nil
                }.joined(separator: "\n")
            let tokens = (response["usage"] as? [String: Any])?["total_tokens"] as? Int
            reply = ChatGPTPlanReply(text: content.isEmpty ? deltaText : content, tokens: tokens.flatMap { $0 >= 0 ? $0 : nil })
        }
    }
}
