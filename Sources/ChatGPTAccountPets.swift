import Foundation
import Darwin

// Use only the Pets connector on the installed Codex app server. Its ephemeral,
// read-only session runs no model turn and leaves sign-in to the host.
private final class PetConnection {
    typealias Object = [String: Any]
    let child = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data(), sequence = 0
    private var threadID = ""

    static let unavailable = PetImportError(message: "Couldn’t load account pets. Check your connection and ChatGPT sign-in, or choose a sprite sheet file.")
    init() throws {
        guard let executable = CodexReply.installedExecutable(allowedURL: PetDiscoveryAccess.allowedURL) else { throw Self.unavailable }
        child.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        child.arguments = PetDiscoveryAccess.helperArguments(executable: executable)
        var environment = ProcessInfo.processInfo.environment
        if let path = environment["CODEX_HOME"], PetDiscoveryAccess.allowedURL(URL(fileURLWithPath: path, isDirectory: true)) == nil {
            environment.removeValue(forKey: "CODEX_HOME")
        }
        child.environment = environment
        child.currentDirectoryURL = FileManager.default.temporaryDirectory
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
    }

    func start() throws {
        _ = try request("initialize", ["clientInfo": ["name": "apple_jack", "version": "1"],
                                       "capabilities": ["experimentalApi": true]])
        try send(["method": "initialized"])
        let started = try request("thread/start", ["ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never",
                                                   "cwd": FileManager.default.temporaryDirectory.path])
        guard let thread = started["thread"] as? Object, let id = thread["id"] as? String else { throw Self.unavailable }
        threadID = id
    }

    func close() {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        let process = child
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { process.terminate() }
        }
    }

    private func send(_ object: Object) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func request(_ method: String, _ params: Object) throws -> Object {
        sequence += 1
        try send(["id": sequence, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + 18
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard let object = try JSONSerialization.jsonObject(with: line) as? Object else { throw Self.unavailable }
                if object["method"] != nil {
                    // A connector or server requesting interaction cannot authorize itself.
                    if let id = object["id"] {
                        try send(["id": id, "error": ["code": -32601, "message": "Unsupported request"]])
                    }
                    continue
                }
                guard object["id"] as? Int == sequence else { continue }
                guard let result = object["result"] as? Object else { throw Self.unavailable }
                return result
            }
            let fd = output.fileHandleForReading.fileDescriptor
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let millis = max(1, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
            let ready = poll(&descriptor, 1, millis)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw Self.unavailable }
            var chunk = [UInt8](repeating: 0, count: 32768)
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, buffer.count + count <= 8 * 1024 * 1024 else { throw Self.unavailable }
            buffer.append(contentsOf: chunk.prefix(count))
        }
        throw Self.unavailable
    }

    func pets(_ name: String, _ arguments: Object) throws -> Object {
        let result = try request("mcpServer/tool/call", ["threadId": threadID, "server": "codex_apps",
                                                          "tool": "pets." + name, "arguments": arguments])
        guard result["isError"] as? Bool != true, let payload = result["structuredContent"] as? Object,
              payload["isError"] as? Bool != true else { throw Self.unavailable }
        return payload["structuredContent"] as? Object ?? payload
    }
}

enum ChatGPTAccountPets {
    private static func connected<T>(_ body: (PetConnection) throws -> T) throws -> T {
        let connection = try PetConnection()
        defer { connection.close() }
        try connection.start()
        return try body(connection)
    }

    static func list() throws -> [ChatGPTPetCandidate] {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return try connected { connection in
            var result: [ChatGPTPetCandidate] = [], ids = Set<String>(), cursors = Set<String>()
            var args: [String: Any] = ["limit": 20]
            repeat {
                let page = try connection.pets("list_pets", args)
                guard let rows = page["pets"] as? [[String: Any]] else { throw PetConnection.unavailable }
                for row in rows {
                    guard let id = row["id"] as? String, !id.isEmpty, ids.insert(id).inserted,
                          let custom = row["is_custom"] as? Bool, let name = row["name"] as? String, !name.isEmpty else { continue }
                    let lock = NSLock()
                    result.append(ChatGPTPetCandidate(id: custom ? id : "builtin:" + id, name: name, sourceName: custom ? "ChatGPT" : "Built-in") {
                        lock.lock()
                        defer { lock.unlock() }
                        if let saved = cache.object(forKey: id as NSString) { return saved as Data }
                        let data = try artwork(id)
                        cache.setObject(data as NSData, forKey: id as NSString, cost: data.count)
                        return data
                    })
                }
                guard let cursor = page["cursor"] as? String, !cursor.isEmpty else { break }
                guard cursors.insert(cursor).inserted else { throw PetConnection.unavailable }
                args["cursor"] = cursor
            } while true
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private static func artwork(_ id: String) throws -> Data {
        let url: URL = try connected { connection in
            let payload = try connection.pets("get_pet_download_link", ["pet_id": id])
            guard payload["pet_id"] as? String == id, let raw = payload["spritesheet_url"] as? String,
                  let url = URL(string: raw), url.scheme == "https", url.host != nil else { throw PetConnection.unavailable }
            return url
        }
        let failure = PetImportError(message: "Couldn’t download this pet’s artwork. Check your connection and try importing it again.")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let ready = DispatchSemaphore(value: 0)
        final class Download: @unchecked Sendable { var data: Data? }
        let result = Download()
        session.downloadTask(with: url) { file, response, error in
            defer { ready.signal() }
            guard error == nil, let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https", let file else { return }
            result.data = try? ImportedPets.readFile(file)
        }.resume()
        guard ready.wait(timeout: .now() + 30) == .success, let data = result.data else { throw failure }
        return data
    }
}
