import Foundation

// Main-thread-owned execution. Run the CLI directly so launching a shortcut
// does not activate the Shortcuts editor. Interactive actions can show their UI.
final class ShortcutRunner {
    private var process: Process?
    private let executable: URL
    var isActive: Bool { process != nil }
    init(executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) { self.executable = executable }

    func run(shortcut: String, input: String? = nil, ignoringUserCancellation: Bool = false, completion: @escaping (String?) -> Void) {
        execute(shortcut: shortcut, input: input, readReply: false, ignoringUserCancellation: ignoringUserCancellation) { outcome in
            if case .failure(let error) = outcome { completion(error.localizedDescription) }
            else { completion(nil) }
        }
    }

    func requestReply(shortcut: String, input: String, completion: @escaping (Result<String, Error>) -> Void) {
        execute(shortcut: shortcut, input: input, readReply: true, ignoringUserCancellation: false, completion: completion)
    }

    private func execute(shortcut: String, input: String?, readReply: Bool, ignoringUserCancellation: Bool,
                         completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let name = shortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { completion(.failure(Self.error("Choose a shortcut to run."))); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppleJackShortcut-" + UUID().uuidString)
        var logHandle: FileHandle?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var arguments = ["run", name]
            let output = directory.appendingPathComponent("reply.txt")
            if readReply { arguments += ["--output-path", output.path, "--output-type", "public.plain-text"] }
            if let input = input {
                // A UTF-8 file preserves quotes, newlines, and non-English text.
                let inputURL = directory.appendingPathComponent("input.txt")
                try input.write(to: inputURL, atomically: true, encoding: .utf8)
                arguments += ["--input-path", inputURL.path]
            }
            let log = directory.appendingPathComponent("status.txt")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            logHandle = handle
            let child = Process()
            child.executableURL = executable
            child.arguments = arguments
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = handle; child.standardError = handle
            child.terminationHandler = { [weak self] finished in
                try? handle.close()
                let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                let details = logText.trimmingCharacters(in: .whitespacesAndNewlines)
                let reply = readReply ? ((try? String(contentsOf: output, encoding: .utf8)) ?? logText) : ""
                try? FileManager.default.removeItem(at: directory)
                DispatchQueue.main.async {
                    guard let self = self, self.process === finished else { return }
                    self.process = nil
                    // Shortcuts returns a nonzero status when a user dismisses
                    // its menu. Only opt-in callers treat that exact diagnostic
                    // as a normal completion; other failures still surface.
                    let wasDismissed = ignoringUserCancellation && finished.terminationReason == .exit
                        && ["Error: Running was cancelled", "Error: Running was canceled"].contains(details)
                    if finished.terminationStatus == 0 || wasDismissed { completion(.success(reply)) }
                    else { completion(.failure(Self.error("Could not run ‘\(name)’. Run that shortcut in Shortcuts to check its setup and permissions.\(details.isEmpty ? "" : "\n" + String(details.prefix(800)))"))) }
                }
            }
            process = child
            try child.run()
        } catch {
            process = nil
            try? logHandle?.close()
            try? FileManager.default.removeItem(at: directory)
            completion(.failure(Self.error("Could not start ‘\(name)’: \(error.localizedDescription)")))
        }
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "AppleJack.Shortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func cancel() {
        guard let child = process else { return }
        process = nil // Ignore completion from this canceled run.
        if child.isRunning {
            child.interrupt()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if child.isRunning { child.terminate() }
            }
        }
    }
}
