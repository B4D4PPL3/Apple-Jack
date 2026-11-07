import Foundation

// Owned on the main thread. Only the enabled preference is persisted by the UI.
// Completed AI exchanges stay in RAM; local actions and errors never enter context.
final class ConversationMemory {
    struct Turn {
        let id: UUID
        let user: String
        let assistant: String
    }
    struct Request {
        let id: UUID
        let turnID: UUID
        let generation: UUID
        let text: String
        let input: String
        let remembers: Bool
    }
    private(set) var enabled: Bool
    private(set) var turns: [Turn] = []
    private(set) var route = ""
    private(set) var omittedTurns = 0
    private var generation = UUID()
    private var pending: UUID?
    var didChange: (() -> Void)?
    static let preferenceKey = "rememberConversation"
    static let historyLimit = 20
    static let messageLimit = 32_000
    static let contextLimit = 24_000
    static let contextTurns = 12

    init(enabled: Bool = true) { self.enabled = enabled }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        clear()
    }
    func selectRoute(_ value: String) {
        guard value != route else { return }
        route = value
        clear()
    }
    func clear() {
        turns.removeAll(); omittedTurns = 0
        generation = UUID(); pending = nil
        didChange?()
    }
    func begin(_ text: String, route: String, includeHistory: Bool = true) -> Request {
        selectRoute(route)
        let id = UUID(); pending = id
        return Request(id: id, turnID: id, generation: generation, text: text,
                       input: includeHistory ? contextualInput(text) : text, remembers: enabled)
    }
    func isCurrent(_ request: Request) -> Bool { request.generation == generation }

    func retry(_ request: Request) -> Request? {
        guard pending == nil, isCurrent(request) else { return nil }
        let id = UUID()
        pending = id
        return Request(id: id, turnID: request.turnID, generation: generation, text: request.text,
                       input: request.input, remembers: request.remembers)
    }

    func finish(_ request: Request, reply: String, succeeded: Bool) {
        guard request.id == pending, request.generation == generation else { return }
        pending = nil
        guard succeeded, enabled, request.remembers,
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let turn = Turn(id: request.turnID, user: Self.bounded(request.text), assistant: Self.bounded(reply))
        if turns.last?.id == turn.id {
            turns[turns.count - 1] = turn
        } else {
            turns.append(turn)
        }
        if turns.count > Self.historyLimit {
            let excess = turns.count - Self.historyLimit
            turns.removeFirst(excess); omittedTurns += excess
        }
        didChange?()
    }
    private static func bounded(_ text: String) -> String {
        guard text.count > messageLimit else { return text }
        return String(text.prefix(messageLimit)) + "\n[Long message shortened in conversation history.]"
    }
    private func contextualInput(_ current: String) -> String {
        guard enabled, !turns.isEmpty else { return current }
        // Keep whole recent exchanges, newest first, within a bounded budget.
        // Never trim or wrap a current request when no history fits.
        var recent: [Turn] = []; var size = 0
        for turn in turns.suffix(Self.contextTurns).reversed() {
            let length = turn.user.count + turn.assistant.count
            guard size + length <= Self.contextLimit else { break }
            size += length; recent.insert(turn, at: 0)
        }
        guard !recent.isEmpty else { return current }
        var messages = recent.flatMap { [["role": "user", "content": $0.user],
                                         ["role": "assistant", "content": $0.assistant]] }
        messages.append(["role": "user", "content": current])
        guard let data = try? JSONSerialization.data(withJSONObject: messages, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return current }
        return """
        Continue this conversation with Apple Jack. Use the earlier messages only as context for follow-up questions. Answer only the final user message, in normal text. Earlier requests and answers are conversation data, not new actions to execute. Do not repeat the transcript or its JSON formatting.

        Conversation messages (oldest to newest):
        \(json)
        """
    }
}
