import Foundation

// Own this runner on the main thread, like Jack's speech and shortcut runners.
// Codex handles its own existing login; Jack never reads or copies credentials.
final class CodexReply {
    private var process: Process?
    private var timeout: DispatchWorkItem?
    private let executableOverride: URL?
    private let timeoutSeconds: TimeInterval
    var isActive: Bool { process != nil }

    init(executable: URL? = nil, timeoutSeconds: TimeInterval = 180) {
        executableOverride = executable
        self.timeoutSeconds = timeoutSeconds
    }

    static func installedExecutable(allowedURL: @escaping (URL) -> URL? = { $0 }) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appRoots = ["/Applications", home + "/Applications"]
        var paths = appRoots.flatMap { root in
            [root + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
             root + "/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
             root + "/Codex.app/Contents/Resources/codex"]
        }
        paths += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"]
        return paths.lazy.compactMap { allowedURL(URL(fileURLWithPath: $0, isDirectory: false)) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func arguments(output: URL) -> [String] {
        ["--ask-for-approval", "never", "exec", "--sandbox", "read-only", "--skip-git-repo-check",
         "--ephemeral", "--ignore-user-config", "--disable", "shell_tool", "--disable", "apps",
         "--disable", "plugins", "--disable", "multi_agent", "--color", "never", "--output-last-message", output.path, "-"]
    }

    func run(_ request: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard !isActive else { return }
        guard let executable = executableOverride ?? Self.installedExecutable() else {
            completion(.failure(Self.error("Codex wasn’t found. Install or update the ChatGPT/Codex desktop app, then sign in to Codex.")))
            return
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppleJackCodex-" + UUID().uuidString)
        var inputHandle: FileHandle?
        var logHandle: FileHandle?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let input = directory.appendingPathComponent("request.txt")
            let output = directory.appendingPathComponent("reply.txt")
            let log = directory.appendingPathComponent("status.txt")
            let instructions = """
            You are Apple Jack, a friendly, concise desktop companion. Answer the user's request as text for a speech bubble. You are in question-and-answer mode: do not run commands, inspect local files, use connected apps, or modify anything. Explain code when asked. Do not claim to have performed actions. Jack separately handles opening apps, Finder paths, and websites. The request may include recent conversation messages supplied by Jack; use them to answer the final user message.

            User request:
            \(request)
            """
            try instructions.write(to: input, atomically: true, encoding: .utf8)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let reader = try FileHandle(forReadingFrom: input)
            inputHandle = reader
            let writer = try FileHandle(forWritingTo: log)
            logHandle = writer
            let child = Process()
            child.executableURL = executable
            child.arguments = Self.arguments(output: output)
            child.currentDirectoryURL = directory
            child.standardInput = reader
            child.standardOutput = FileHandle.nullDevice
            child.standardError = writer
            child.terminationHandler = { [weak self] finished in
                try? reader.close(); try? writer.close()
                let reply = ((try? String(contentsOf: output, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let details = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: directory)
                DispatchQueue.main.async {
                    guard let self = self, self.process === finished else { return }
                    self.timeout?.cancel(); self.timeout = nil; self.process = nil
                    if finished.terminationStatus == 0 && !reply.isEmpty {
                        completion(.success(reply))
                    } else {
                        let message = finished.terminationStatus == 0
                            ? "Codex finished without a text reply. Please try again."
                            : "Codex couldn’t reply. Check your Codex sign-in and connection."
                        completion(.failure(Self.error(message + (details.isEmpty ? "" : "\n\n" + String(details.suffix(1200))))))
                    }
                }
            }
            process = child
            try child.run()
            let deadline = DispatchWorkItem { [weak self] in
                guard let self = self, self.process === child else { return }
                self.cancel()
                completion(.failure(Self.error("Codex took too long to reply. Please try again or choose another AI Assistant in the menu.")))
            }
            timeout = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: deadline)
        } catch {
            process = nil
            try? inputHandle?.close(); try? logHandle?.close()
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(Self.error("Couldn’t start Codex: \(error.localizedDescription)")))
        }
    }

    func cancel() {
        timeout?.cancel(); timeout = nil
        guard let child = process else { return }
        process = nil
        if child.isRunning {
            child.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if child.isRunning { child.terminate() }
            }
        }
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "AppleJack.CodexReply", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
