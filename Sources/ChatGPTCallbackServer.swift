import Foundation
import Network

// A single-use, time-limited OAuth callback bound only to this Mac. Request
// paths and headers are never logged; they may contain an authorization code.
final class ChatGPTCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fonz.applejack.chatgpt-callback")
    private let listener: NWListener
    private var pending: CheckedContinuation<URL, Error>?
    private var connections = [ObjectIdentifier: NWConnection]()
    private var stopped = false
    private var received = false
    private var callbackURL: URL?
    private let state: String
    private let clientID: String?
    private let completion: (Result<ChatGPTSignInProtocol.Callback, Error>) -> Void

    init(state: String, clientID: String?, completion: @escaping (Result<ChatGPTSignInProtocol.Callback, Error>) -> Void) throws {
        self.state = state; self.clientID = clientID; self.completion = completion
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !stopped else { continuation.resume(throwing: CancellationError()); return }
                pending = continuation
                listener.stateUpdateHandler = { [weak self] value in
                    guard let self else { return }
                    switch value {
                    case .ready:
                        guard let port = self.listener.port, let pending = self.pending else { return }
                        let url = URL(string: "http://127.0.0.1:\(port.rawValue)" + ChatGPTSignInProtocol.callbackPath)!
                        self.callbackURL = url; self.pending = nil; pending.resume(returning: url)
                    case .failed:
                        self.pending?.resume(throwing: ChatGPTConnectionError("Couldn’t start the local sign-in connection. Please try again."))
                        self.pending = nil; self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, let pending = self.pending else { return }
                    self.pending = nil
                    pending.resume(throwing: ChatGPTConnectionError("The local sign-in connection took too long to start."))
                    self.stopOnQueue()
                }
            }
        }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        pending?.resume(throwing: CancellationError()); pending = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, !received, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak connection] in
            guard let self, let connection, self.connections[ObjectIdentifier(connection)] != nil else { return }
            self.close(connection)
        }
        receive(connection, data: Data())
    }
    private func close(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection)); connection.cancel()
    }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] bytes, _, complete, error in
            guard let self, !self.stopped else { return }
            let data = data + (bytes ?? Data())
            guard data.count <= 20_000, error == nil else { self.close(connection); return }
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { self.handle(connection, data: data) }
            else if complete { self.close(connection) }
            else { self.receive(connection, data: data) }
        }
    }
    private func handle(_ connection: NWConnection, data: Data) {
        guard !received, let expected = callbackURL, let request = String(data: data, encoding: .utf8) else { close(connection); return }
        let lines = request.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        let hosts = lines.filter { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        guard first.count == 3, first[0] == "GET", first[1].hasPrefix(ChatGPTSignInProtocol.callbackPath + "?"),
              hosts == ["127.0.0.1:\(expected.port!)"],
              let url = URL(string: "http://127.0.0.1:\(expected.port!)" + first[1]),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              let value = items.first(where: { $0.name == "state" })?.value,
              ChatGPTSignInProtocol.equal(value, state) else {
            respond(connection, status: "400 Bad Request", message: "Start sign-in from Apple Jack.", after: nil); return
        }
        let result = Result { try ChatGPTSignInProtocol.callback(url, expectedURL: expected, state: state, clientID: clientID) }
        received = true
        respond(connection, status: "200 OK", message: "Return to Apple Jack to finish connecting. You can close this browser tab.") { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            DispatchQueue.main.async { self.completion(result) }
        }
    }
    private func respond(_ connection: NWConnection, status: String, message: String, after: (() -> Void)?) {
        let body = Data(("<!doctype html><meta charset=\"utf-8\"><title>Apple Jack</title><h1>Apple Jack</h1><p>" + message + "</p>").utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.close(connection); after?()
        })
    }
}
