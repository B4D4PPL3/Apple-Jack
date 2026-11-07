import Foundation

final class ShortcutSpeech {
    private let runner: ShortcutRunner
    var isActive: Bool { runner.isActive }

    init(executable: URL = URL(fileURLWithPath: "/usr/bin/shortcuts")) {
        runner = ShortcutRunner(executable: executable)
    }

    func play(_ text: String, shortcut: String, completion: @escaping (String?) -> Void) {
        guard !shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancel()
            completion("Choose a speech shortcut in Menu → Speech & Input → Voice.")
            return
        }
        runner.run(shortcut: shortcut, input: text, completion: completion)
    }

    func cancel() { runner.cancel() }
}
