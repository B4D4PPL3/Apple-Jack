import Foundation

enum AIBackend: String, CaseIterable {
    case shortcut, chatGPT, codex

    static var selected: AIBackend {
        get {
            return AIBackend(rawValue: UserDefaults.standard.string(forKey: "aiBackend") ?? "") ?? .shortcut
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "aiBackend")
        }
    }

    var title: String {
        switch self {
        case .shortcut: return "Current Shortcut"
        case .chatGPT: return "ChatGPT"
        case .codex: return "Codex"
        }
    }

    static var chatGPTShortcut: String {
        get {
            let saved = (UserDefaults.standard.string(forKey: "chatGPTShortcut") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return saved.isEmpty ? "Ask Apple Jack (ChatGPT)" : saved
        }
        set { UserDefaults.standard.set(newValue, forKey: "chatGPTShortcut") }
    }
}
