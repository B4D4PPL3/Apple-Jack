import AppKit

// UI-owned on the main thread. Network continuations return through MainActor;
// an operation identifier prevents late callbacks from reviving a canceled run.
final class ChatGPTConnection {
    private let storage: ChatGPTCredentialStore
    private let http: ChatGPTHTTPClient
    private var unsavedRotation = [UUID: ChatGPTCredentials]()
    private var saved = ChatGPTConnections()
    private var storageError: Error?
    private(set) var hasLoadedConnection = false
    var needsUnlock: Bool { !hasLoadedConnection || storageError != nil }
    private var authID: UUID?
    private var authTask: Task<Void, Never>?
    private var authTimeout: DispatchWorkItem?
    private var callbackServer: ChatGPTCallbackServer?
    private var requestID: UUID?
    private var requestTask: Task<Void, Never>?
    private var settingsTask: Task<Void, Never>?
    private var refreshTask: Task<ChatGPTCredentials, Error>?
    private var pendingClientID: String?
    private(set) var models = [ChatGPTPlanModel]()
    private(set) var status = "Your ChatGPT connection loads only when you use it. Choose Unlock ChatGPT Connection if macOS needs permission."
    private(set) var lastReplyTokens: Int?
    private(set) var completedReplies = 0
    private(set) var usageLimited = false
    var didChange: (() -> Void)?
    var profiles: [ChatGPTProfile] { saved.profiles }
    var activeProfile: ChatGPTProfile? { saved.profiles.first { $0.id == saved.selectedID } }
    var isSigningIn: Bool { authID != nil }
    var isActive: Bool { requestID != nil }
    var isBusy: Bool { isSigningIn || isActive || settingsTask != nil || refreshTask != nil }
    var canUsePlan: Bool { activeProfile?.credentials?.canUsePlan == true }
    var route: String { activeProfile?.id.uuidString ?? "signed-out" }
    var needsWelcome: Bool { canUsePlan && activeProfile?.welcomed == false }
    var usageSummary: String {
        if needsUnlock { return "ChatGPT • Connection locked" }
        guard activeProfile?.credentials != nil else { return "ChatGPT • Not connected" }
        guard canUsePlan else { return "ChatGPT • Plan use is off" }
        if usageLimited { return "ChatGPT • Usage limit reached" }
        return "Using ChatGPT plan" + (completedReplies > 0 ? " · \(completedReplies) \(completedReplies == 1 ? "reply" : "replies") this session" : "")
    }
    init(storage: ChatGPTCredentialStore = ChatGPTKeychainStore(), http: ChatGPTHTTPClient = ChatGPTPlanHTTP()) {
        self.storage = storage; self.http = http
        // Do not query Keychain at launch, even if this assistant is selected.
    }
    private func changed() { didChange?() }
    @discardableResult func loadIfNeeded() -> Bool {
        if hasLoadedConnection && storageError == nil { return true }
        // Once macOS refused a silent read, wait for the user's Unlock action.
        if storageError != nil { return false }
        return load(allowUserInteraction: false)
    }
    @discardableResult func unlock() -> Bool {
        guard !isBusy else { return false }
        if hasLoadedConnection && storageError == nil { return true }
        return load(allowUserInteraction: true)
    }
    private func load(allowUserInteraction: Bool) -> Bool {
        do {
            let value = try storage.read(allowUserInteraction: allowUserInteraction)
            saved = value; hasLoadedConnection = true; storageError = nil
            if let profile = activeProfile {
                status = profile.credentials == nil ? "Sign in again to reconnect this account." : "Connected to \(profile.email)."
            } else { status = "Connect your ChatGPT account to reply directly in Jack." }
            changed(); return true
        } catch {
            storageError = error; status = error.localizedDescription
            changed(); return false
        }
    }
    private func save(_ value: ChatGPTConnections) throws {
        guard hasLoadedConnection else { throw ChatGPTStorageError.locked }
        if let storageError { throw storageError }
        do { try storage.write(value); saved = value }
        catch {
            storageError = error; changed()
            throw error
        }
    }
    private func update(_ profile: ChatGPTProfile, select: Bool = false) throws {
        var value = saved
        if let i = value.profiles.firstIndex(where: { $0.id == profile.id }) { value.profiles[i] = profile }
        else { value.profiles.append(profile) }
        if select { value.selectedID = profile.id }
        try save(value)
    }
    func selectProfile(_ id: UUID) {
        guard !isBusy, saved.profiles.contains(where: { $0.id == id }) else { return }
        do {
            var value = saved; value.selectedID = id; try save(value)
            models = []; completedReplies = 0; lastReplyTokens = nil; usageLimited = false
            status = activeProfile?.credentials == nil ? "Sign in to reconnect this account." : "Connected. Refresh the available models."
            changed()
            if canUsePlan { refreshModels() }
        } catch { status = error.localizedDescription; changed() }
    }
    func selectModel(_ slug: String) {
        guard !isBusy, models.contains(where: { $0.slug == slug }), var profile = activeProfile else { return }
        do { profile.model = slug; try update(profile); changed() }
        catch { status = error.localizedDescription; changed() }
    }
    func acknowledgeWelcome() {
        guard var profile = activeProfile else { return }
        do { profile.welcomed = true; try update(profile); changed() }
        catch { status = error.localizedDescription; changed() }
    }
    func signIn(newAccount: Bool = false) {
        guard !isBusy else { return }
        guard loadIfNeeded() else { return }
        let previous = newAccount ? nil : activeProfile
        let clientID = previous?.clientID ?? (newAccount ? nil : pendingClientID)
        let id = UUID(); authID = id
        status = "Finish signing in with OpenAI in your browser."
        changed()
        authTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try ChatGPTSignInProtocol.random(), nonce = try ChatGPTSignInProtocol.random(), verifier = try ChatGPTSignInProtocol.random()
                let server = try ChatGPTCallbackServer(state: state, clientID: clientID) { [weak self] outcome in
                    guard let self, self.authID == id else { return }
                    self.finishSignIn(outcome, id: id, previous: previous, nonce: nonce, verifier: verifier)
                }
                self.callbackServer = server
                let callback = try await server.start()
                try Task.checkCancellation()
                guard self.authID == id else { server.stop(); return }
                self.pendingCallback = callback
                let defaults = UserDefaults.standard
                let host = defaults.string(forKey: "chatGPTSignInHostID") ?? "urn:uuid:" + UUID().uuidString.lowercased()
                defaults.set(host, forKey: "chatGPTSignInHostID")
                let url = ChatGPTSignInProtocol.authorize(host: host, callback: callback, state: state, nonce: nonce,
                    verifier: verifier, clientID: clientID, email: previous?.email,
                    askConsent: previous?.credentials != nil && previous?.credentials?.canUsePlan == false)
                guard NSWorkspace.shared.open(url) else { throw ChatGPTConnectionError("Couldn’t open your browser. Check the default browser in System Settings, then try again.") }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.authID == id else { return }
                    self.cancelSignIn(message: "Sign-in timed out. You can start again whenever you’re ready.")
                }
                self.authTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 240, execute: timeout)
            } catch {
                guard self.authID == id else { return }
                self.cancelSignIn(message: Self.message(error))
            }
        }
    }
    private var pendingCallback: URL?
    private func finishSignIn(_ outcome: Result<ChatGPTSignInProtocol.Callback, Error>, id: UUID,
                              previous: ChatGPTProfile?, nonce: String, verifier: String) {
        guard authID == id, let callback = pendingCallback else { return }
        authTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let authorization = try outcome.get()
                if previous == nil { self.pendingClientID = authorization.clientID }
                self.status = "Verifying your ChatGPT connection…"; self.changed()
                let data = try await self.http.data(URL(string: ChatGPTSignInProtocol.issuer + "/api/accounts/oauth/token")!, form: [
                    "grant_type": "authorization_code", "client_id": authorization.clientID, "code": authorization.code,
                    "code_verifier": verifier, "redirect_uri": callback.absoluteString, "resource": ChatGPTSignInProtocol.resource
                ])
                let credentials = try Self.credentials(data)
                let keys = try await self.http.publishedKeys()
                let identity = try ChatGPTSignInProtocol.identity(credentials.idToken, keys: keys, clientID: authorization.clientID,
                    nonce: nonce, expectedSubject: previous?.subject)
                try Task.checkCancellation()
                guard self.authID == id else { return }
                var profile = previous ?? ChatGPTProfile(id: UUID(), clientID: authorization.clientID,
                    issuer: identity.issuer, subject: identity.subject, email: identity.email, credentials: nil, model: nil)
                profile.email = identity.email; profile.credentials = credentials; profile.pendingCredentials = nil
                try self.update(profile, select: true)
                self.unsavedRotation.removeValue(forKey: profile.id)
                self.models = []; self.completedReplies = 0; self.lastReplyTokens = nil; self.usageLimited = false
                self.pendingClientID = nil
                self.endAuth()
                self.status = credentials.canUsePlan ? "You’re using your ChatGPT plan. Eligible requests count toward its existing limits."
                    : ChatGPTConnectionError.noPermission.message
                self.changed()
                NSApp.activate(ignoringOtherApps: true)
                if credentials.canUsePlan { self.refreshModels() }
            } catch {
                guard self.authID == id else { return }
                self.cancelSignIn(message: Self.message(error))
            }
        }
    }
    private func endAuth() {
        authID = nil; authTask = nil; authTimeout?.cancel(); authTimeout = nil
        callbackServer?.stop(); callbackServer = nil; pendingCallback = nil
    }
    func cancelSignIn(message: String = "Sign-in canceled. Your saved connections are unchanged.") {
        guard isSigningIn else { return }
        authTask?.cancel(); endAuth(); status = message; changed()
    }
    static func credentials(_ data: Data, replacing old: ChatGPTCredentials? = nil) throws -> ChatGPTCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty,
              (root["token_type"] as? String)?.lowercased() == "bearer",
              let expires = root["expires_in"] as? Double, expires > 0, expires <= 86_400,
              let token = root["id_token"] as? String ?? old?.idToken, !token.isEmpty else { throw ChatGPTConnectionError.invalidSignIn }
        let scopes = (root["scope"] as? String)?.split(separator: " ").map(String.init) ?? old?.scopes ?? []
        return ChatGPTCredentials(accessToken: access, refreshToken: root["refresh_token"] as? String ?? old?.refreshToken,
            idToken: token, expiresAt: Date().addingTimeInterval(expires), scopes: scopes)
    }
    @MainActor private func usableCredentials() async throws -> ChatGPTCredentials {
        guard let profile = activeProfile, let credentials = profile.credentials else { throw ChatGPTConnectionError.signedOut }
        guard credentials.canUsePlan else { throw ChatGPTConnectionError.noPermission }
        let pending = unsavedRotation[profile.id] ?? profile.pendingCredentials
        if pending == nil && credentials.expiresAt.timeIntervalSinceNow > 90 { return credentials }
        if let refreshTask { return try await refreshTask.value }
        guard pending != nil || credentials.refreshToken?.isEmpty == false else { throw ChatGPTConnectionError.signedOut }
        // Refresh has its own task: canceling a reply must not discard a rotating
        // refresh token after OpenAI has already issued its replacement.
        let task = Task { @MainActor [self] () throws -> ChatGPTCredentials in
            do {
                let renewed: ChatGPTCredentials
                if let pending { renewed = pending }
                else {
                    let data = try await http.data(URL(string: ChatGPTSignInProtocol.issuer + "/api/accounts/oauth/token")!, form: [
                        "grant_type": "refresh_token", "client_id": profile.clientID, "refresh_token": credentials.refreshToken!,
                        "resource": ChatGPTSignInProtocol.resource
                    ])
                    renewed = try Self.credentials(data, replacing: credentials)
                }
                unsavedRotation[profile.id] = renewed
                var staged = profile; staged.pendingCredentials = renewed
                try update(staged)
                if renewed.idToken != credentials.idToken {
                    let keys = try await http.publishedKeys()
                    _ = try ChatGPTSignInProtocol.identity(renewed.idToken, keys: keys, clientID: profile.clientID,
                        nonce: nil, expectedSubject: profile.subject)
                }
                var updated = profile; updated.credentials = renewed; updated.pendingCredentials = nil
                try update(updated); unsavedRotation.removeValue(forKey: profile.id)
                guard renewed.canUsePlan else { throw ChatGPTConnectionError.noPermission }
                return renewed
            } catch {
                if (error as? ChatGPTConnectionError)?.invalidRefresh == true {
                    var updated = profile; updated.credentials = nil; updated.pendingCredentials = nil
                    try update(updated); unsavedRotation.removeValue(forKey: profile.id)
                }
                throw error
            }
        }
        refreshTask = task
        defer { refreshTask = nil; changed() }
        return try await task.value
    }
    @MainActor private func fetchModels(token: String) async throws {
        let data = try await http.data(URL(string: ChatGPTSignInProtocol.resource + "/models")!, token: token)
        let catalog = try ChatGPTPlanModel.catalog(data)
        try Task.checkCancellation()
        guard !catalog.isEmpty else { throw ChatGPTConnectionError("No supported models are available for this ChatGPT account. Check Manage Usage or choose another assistant.") }
        models = catalog
        if var profile = activeProfile, !catalog.contains(where: { $0.slug == profile.model }) {
            profile.model = catalog[0].slug; try update(profile)
        }
    }
    func refreshModels() {
        guard !isBusy, loadIfNeeded() else { return }
        status = "Checking available models…"
        settingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.settingsTask = nil; self.changed() }
            do {
                let credentials = try await self.usableCredentials()
                try await self.fetchModels(token: credentials.accessToken)
                self.status = "Connected. Using your ChatGPT plan."
            } catch { self.status = Self.message(error) }
        }
        changed()
    }
    func run(_ input: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard !isBusy else { completion(.failure(ChatGPTConnectionError("Finish connecting ChatGPT before sending a question."))); return }
        guard loadIfNeeded() else { completion(.failure(storageError ?? ChatGPTStorageError.locked)); return }
        let id = UUID(); requestID = id
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome: Result<String, Error>
            do {
                let credentials = try await self.usableCredentials()
                if self.models.isEmpty { try await self.fetchModels(token: credentials.accessToken) }
                guard let model = self.activeProfile?.model, self.models.contains(where: { $0.slug == model }) else {
                    throw ChatGPTConnectionError("Choose an available model in ChatGPT Connection.")
                }
                try Task.checkCancellation()
                let reply = try await self.http.reply(input: input, model: model, token: credentials.accessToken)
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                self.lastReplyTokens = reply.tokens; self.completedReplies += 1; self.usageLimited = false
                outcome = .success(reply.text)
            } catch {
                guard self.requestID == id else { return }
                self.usageLimited = (error as? ChatGPTConnectionError)?.isUsageLimit == true
                outcome = .failure(ChatGPTConnectionError(Self.message(error), code: (error as? ChatGPTConnectionError)?.code))
            }
            guard self.requestID == id else { return }
            self.requestID = nil; self.requestTask = nil
            self.changed(); completion(outcome)
        }
        changed()
    }
    func cancel() { requestID = nil; requestTask?.cancel(); requestTask = nil; changed() }
    func signOut() {
        guard !isBusy, let profile = activeProfile else { return }
        status = "Signing out…"
        settingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let refreshToken = self.unsavedRotation[profile.id]?.refreshToken ?? profile.pendingCredentials?.refreshToken ?? profile.credentials?.refreshToken
            var revoked = refreshToken == nil
            if let refresh = refreshToken {
                for attempt in 0..<2 {
                    do {
                        let discovery = try await self.http.discovery()
                        guard let value = discovery["revocation_endpoint"] as? String, let endpoint = URL(string: value),
                              ChatGPTPlanHTTP.allowed(endpoint), endpoint.host == "auth.openai.com" else { throw ChatGPTConnectionError.invalidSignIn }
                        _ = try await self.http.data(endpoint, form: ["token": refresh, "token_type_hint": "refresh_token", "client_id": profile.clientID])
                        revoked = true; break
                    } catch { if attempt == 0 { try? await Task.sleep(nanoseconds: 500_000_000) } }
                }
            }
            do {
                var updated = profile; updated.credentials = nil; updated.pendingCredentials = nil
                try self.update(updated); self.unsavedRotation.removeValue(forKey: profile.id)
                self.models = []; self.lastReplyTokens = nil; self.completedReplies = 0; self.usageLimited = false
                self.status = revoked ? "Signed out on this Mac. Your ChatGPT shortcut connection is unchanged."
                    : "Signed out on this Mac. OpenAI couldn’t confirm disconnection. You can also disconnect Apple Jack in ChatGPT Settings → Security and login → Sign in with ChatGPT."
            } catch { self.status = Self.message(error) }
            self.settingsTask = nil; self.changed()
        }
        changed()
    }
    static func message(_ error: Error) -> String {
        if let error = error as? ChatGPTStorageError { return error.localizedDescription }
        if let error = error as? ChatGPTConnectionError { return error.message }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return "Request canceled." }
        // Network errors may include full URLs; don't surface OAuth query values.
        return "Couldn’t reach ChatGPT. Check your internet connection and try again. Your saved connection has been kept."
    }
}
