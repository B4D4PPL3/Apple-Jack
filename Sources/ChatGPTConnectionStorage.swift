import Foundation
import Security

struct ChatGPTCredentials: Codable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String
    var expiresAt: Date
    var scopes: [String]
    var canUsePlan: Bool { scopes.contains(ChatGPTSignInProtocol.planScope) && scopes.contains("resource.invoke") }
}
struct ChatGPTProfile: Codable, Identifiable {
    var id: UUID
    var clientID: String
    var issuer: String
    var subject: String
    var email: String
    var credentials: ChatGPTCredentials?
    var model: String?
    // A rotating refresh token must survive a temporary failure fetching the
    // signing keys. Pending credentials cannot be used for inference.
    var pendingCredentials: ChatGPTCredentials? = nil
    var welcomed = false
    var label: String { email + " · " + String(id.uuidString.prefix(4)) }
}
struct ChatGPTConnections: Codable {
    var profiles = [ChatGPTProfile]()
    var selectedID: UUID?
}

protocol ChatGPTCredentialStore {
    func read(allowUserInteraction: Bool) throws -> ChatGPTConnections
    func write(_ value: ChatGPTConnections) throws
}

enum ChatGPTStorageError: LocalizedError {
    case locked, unreadable
    var errorDescription: String? {
        switch self {
        case .locked: return "Choose Unlock ChatGPT Connection to allow Jack to use your saved sign-in. Your account is still saved securely on this Mac."
        case .unreadable: return "Jack couldn’t read the saved ChatGPT connection. Your saved account has not been changed. Try Unlock ChatGPT Connection again."
        }
    }
}

// Separate from Codex, the Apple Intelligence extension and other editions of Apple Jack.
// No tokens are saved in preferences, iCloud, exported reports or app resources.
struct ChatGPTKeychainStore: ChatGPTCredentialStore {
    var service = (Bundle.main.bundleIdentifier ?? "com.fonz.applejack.public") + ".chatgpt-sign-in"
    // These are legacy login-Keychain items. kSecUseAuthenticationUIFail alone
    // does not reliably suppress UI for that Keychain. Scope the legacy switch
    // to this synchronous operation and restore it, even when the operation fails.
    private static let accessLock = NSLock()
    private func access<T>(allowUserInteraction: Bool, _ body: () throws -> T) throws -> T {
        Self.accessLock.lock()
        defer { Self.accessLock.unlock() }
        if allowUserInteraction { return try body() }
        var previous: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
            throw ChatGPTStorageError.locked
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try body()
    }
    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: "connections-v1", kSecAttrSynchronizable: false]
    }
    func read(allowUserInteraction: Bool) throws -> ChatGPTConnections {
        var q = query
        q[kSecReturnData] = true; q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = try access(allowUserInteraction: allowUserInteraction) {
            SecItemCopyMatching(q as CFDictionary, &result)
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw ChatGPTStorageError.locked
        }
        if status == errSecItemNotFound { return ChatGPTConnections() }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(ChatGPTConnections.self, from: data) else {
            throw ChatGPTStorageError.unreadable
        }
        return value
    }
    func write(_ value: ChatGPTConnections) throws {
        let data = try JSONEncoder().encode(value)
        let status = try access(allowUserInteraction: false) {
            // Updating an existing generic-password item can be allowed even
            // when reading it is not. Never replace a connection we cannot read.
            var readable = query
            readable[kSecReturnData] = true; readable[kSecMatchLimit] = kSecMatchLimitOne
            var existing: CFTypeRef?
            let readableStatus = SecItemCopyMatching(readable as CFDictionary, &existing)
            guard readableStatus == errSecSuccess || readableStatus == errSecItemNotFound else { return readableStatus }
            let updated = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard updated == errSecItemNotFound else { return updated }
            var q = query
            q[kSecValueData] = data
            q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            q[kSecAttrLabel] = "Apple Jack — ChatGPT Connection"
            return SecItemAdd(q as CFDictionary, nil)
        }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
            throw ChatGPTStorageError.locked
        }
        guard status == errSecSuccess else {
            throw ChatGPTConnectionError("Jack couldn’t save the ChatGPT connection in your Mac’s Keychain. Please allow Keychain access and try again.")
        }
    }
}
