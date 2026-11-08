import AppKit

/// A text-only conversation with the user's own installation of Claude Code.
final class ClaudeReply {
    private var process: Process?
    private var timeout: DispatchWorkItem?
    var isActive: Bool { process != nil }

    static func installedExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        let fm = FileManager.default
        let standard = [home.appendingPathComponent(".local/bin/claude"), URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                        URL(fileURLWithPath: "/usr/local/bin/claude")]
        let fromPath = searchPath.split(separator: ":").filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
        func executable(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue && fm.isExecutableFile(atPath: url.path)
        }
        if let url = (standard + fromPath).first(where: executable) { return url }
        // Claude Desktop keeps its signed CLI in version/build-specific subdirectories.
        let cache = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        func children(_ parent: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        }
        for version in children(cache) {
            for build in children(version) {
                let cli = build.appendingPathComponent("claude.app/Contents/MacOS/claude")
                if executable(cli) { return cli }
            }
        }
        return nil
    }

    static func showSetup() {
        let executable = installedExecutable()
        let alert = NSAlert()
        alert.messageText = "Set up Claude (Beta)"
        alert.informativeText = executable == nil
            ? "Install Claude Code on this Mac, sign in with your Claude account, then choose Claude (Beta) in Jack’s AI Assistant menu."
            : "Choose Copy Sign-In Command, paste it into Terminal, and finish signing in with Anthropic using an account with Claude Code access. Then choose Claude (Beta) in Jack’s AI Assistant menu."
        if executable != nil { alert.addButton(withTitle: "Copy Sign-In Command") }
        let guide = alert.addButton(withTitle: "Installation Guide")
        alert.addButton(withTitle: "Close").keyEquivalent = "\u{1b}"
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard alert.buttons.indices.contains(index) else { return }
        if alert.buttons[index] === guide {
            NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs/en/quickstart")!)
        } else if index == 0, let executable {
            let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(quoted + " auth login", forType: .string)
        }
    }

    static let arguments = [
        "--print", "--output-format", "json", "--safe-mode", "--tools", "", "--strict-mcp-config",
        "--no-chrome", "--disable-slash-commands", "--permission-mode", "dontAsk", "--no-session-persistence",
        "--system-prompt", "You are Apple Jack, a concise desktop companion. Answer the user's question in plain text for a speech bubble. Use any conversation context supplied by Jack. Jack handles desktop actions separately."
    ]
    private struct Envelope: Decodable {
        let type: String
        let is_error: Bool
        let result: String?
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AppleJack.Claude", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static var signedOutError: NSError {
        failure("Claude Code is signed out on this Mac. Choose Menu → AI Assistant → Claude Code Setup, then copy the sign-in command into Terminal. You’ll need an account with Claude Code access.")
    }
    private struct AuthStatus: Decodable { let loggedIn: Bool }
    private static func decodeAuth(_ data: Data, status: Int32) -> Result<Void, Error> {
        guard let auth = try? JSONDecoder().decode(AuthStatus.self, from: data) else {
            return .failure(failure("Couldn’t check your Claude Code sign-in. Update Claude Code and open Menu → AI Assistant → Claude Code Setup."))
        }
        return auth.loggedIn && status == 0 ? .success(()) : .failure(signedOutError)
    }
    static func decode(_ data: Data, status: Int32) -> Result<String, Error> {
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        let text = envelope?.result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status == 0, envelope?.type == "result", envelope?.is_error == false, !text.isEmpty {
            return .success(text)
        }
        if envelope?.is_error == true, text.localizedCaseInsensitiveContains("not logged in") {
            return .failure(signedOutError)
        }
        if envelope == nil {
            return .failure(failure("Claude Code didn’t return a readable reply. Update Claude Code, then check Menu → AI Assistant → Claude Code Setup."))
        }
        let hint = "Claude couldn’t reply. Check your Claude Code sign-in in Menu → AI Assistant → Claude Code Setup, your connection, and your plan’s usage limits."
        let detail = envelope?.is_error == true && !text.isEmpty ? "\n\n" + String(text.prefix(600)) : ""
        return .failure(failure(hint + detail))
    }

    func run(_ input: String, executable: URL? = nil, timeoutSeconds: TimeInterval = 180,
             completion: @escaping (Result<String, Error>) -> Void) {
        guard !isActive else { return }
        guard let cli = executable ?? Self.installedExecutable() else {
            completion(.failure(Self.failure("Install Claude Code and sign in on this Mac. Choose Menu → AI Assistant → Claude Code Setup to get started.")))
            return
        }
        execute(cli, arguments: ["auth", "status"], input: "", timeoutSeconds: 15,
                timeoutMessage: "Claude Code sign-in didn’t respond. Open Menu → AI Assistant → Claude Code Setup.",
                decode: Self.decodeAuth) { [weak self] status in
            switch status {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                self?.execute(cli, arguments: Self.arguments, input: input, timeoutSeconds: timeoutSeconds,
                              timeoutMessage: "Claude took too long to reply. You can try the question again.",
                              decode: Self.decode, completion: completion)
            }
        }
    }

    private func execute<T>(_ cli: URL, arguments: [String], input: String, timeoutSeconds: TimeInterval,
                            timeoutMessage: String, decode: @escaping (Data, Int32) -> Result<T, Error>,
                            completion: @escaping (Result<T, Error>) -> Void) {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("AppleJackClaude-" + UUID().uuidString, isDirectory: true)
        let inputFile = folder.appendingPathComponent("input"), outputFile = folder.appendingPathComponent("result")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data(input.utf8).write(to: inputFile)
            try Data().write(to: outputFile)
            let reader = try FileHandle(forReadingFrom: inputFile), writer = try FileHandle(forWritingTo: outputFile)
            let child = Process()
            child.executableURL = cli
            child.arguments = arguments
            child.currentDirectoryURL = folder
            child.standardInput = reader
            child.standardOutput = writer
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] finished in
                let data = (try? Data(contentsOf: outputFile)) ?? Data()
                try? fm.removeItem(at: folder)
                let result = decode(data, finished.terminationStatus)
                DispatchQueue.main.async {
                    guard let self, self.process === finished else { return }
                    self.timeout?.cancel(); self.timeout = nil; self.process = nil
                    completion(result)
                }
            }
            defer { try? reader.close(); try? writer.close() }
            try child.run()
            process = child
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.process === child else { return }
                self.cancel()
                completion(.failure(Self.failure(timeoutMessage)))
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
        } catch {
            try? fm.removeItem(at: folder)
            completion(.failure(Self.failure("Couldn’t start Claude Code. " + error.localizedDescription)))
        }
    }

    func cancel() {
        timeout?.cancel(); timeout = nil
        guard let child = process else { return }
        process = nil
        guard child.isRunning else { return }
        child.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if child.isRunning { child.terminate() }
        }
    }
}
