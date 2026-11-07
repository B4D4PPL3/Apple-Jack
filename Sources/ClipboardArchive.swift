import Foundation
import CryptoKit

struct ClipboardEntry: Codable, Identifiable {
    enum Kind: String, Codable { case text, image, files }
    let id: UUID
    let kind: Kind
    let fingerprint: String
    let text: String
    let items: [[String: Data]]
    var date: Date
    var source: String
    var pinned: Bool
    var byteCount: Int { text.utf8.count + source.utf8.count + 512 + items.reduce(0) { $0 + $1.values.reduce(0) { $0 + $1.count } } }
    var title: String {
        switch kind {
        case .text: return String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(160) ?? "Text".prefix(160))
        case .image: return "Copied image"
        case .files:
            let names = fileURLs.map(\.lastPathComponent)
            return names.count == 1 ? names[0] : "\(names.count) files · \(names.prefix(3).joined(separator: ", "))"
        }
    }
    var fileURLs: [URL] { items.compactMap { $0["public.file-url"].flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)) } }
    // Shared by Copy Plain Text and Use in Jack. File paths do not require the
    // original files to remain available; raw image data has no source path.
    var textRepresentation: String? {
        switch kind {
        case .text: return text
        case .files:
            let urls = fileURLs
            guard !urls.isEmpty, urls.count == items.count, urls.allSatisfy(\.isFileURL) else { return nil }
            return urls.map(\.path).joined(separator: "\n")
        case .image: return nil
        }
    }
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty || (title + "\n" + text + "\n" + source).localizedStandardContains(q)
    }
    static func make(kind: Kind, text: String, items: [[String: Data]], source: String, date: Date = Date()) -> Self {
        var hash = SHA256()
        for item in items {
            hash.update(data: Data([0]))
            for key in item.keys.sorted() {
                let data = item[key]!
                hash.update(data: Data("\(key.utf8.count):\(key):\(data.count):".utf8)); hash.update(data: data)
            }
        }
        return Self(id: UUID(), kind: kind, fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), text: text,
                    items: items, date: date, source: source, pinned: false)
    }
}

struct ClipboardFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// Confined to ClipboardHistory's serial queue. No cloud, network, or AI access.
final class ClipboardArchive {
    static let entryLimit = 100
    static let byteLimit = 64 * 1_024 * 1_024
    static let itemByteLimit = 12 * 1_024 * 1_024
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    private struct Document: Codable { let version: Int; let entries: [ClipboardEntry] }
    let directory: URL
    private(set) var entries: [ClipboardEntry] = []
    private var file: URL { directory.appendingPathComponent("History.plist") }
    init(directory: URL) throws {
        self.directory = directory
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw ClipboardFailure(message: "Clipboard storage must be a local folder, not a link.")
            }
        }
        if manager.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= Self.byteLimit + 4_194_304 else {
                throw ClipboardFailure(message: "Clipboard history could not be loaded. The saved file is too large or is a link.")
            }
            let document = try PropertyListDecoder().decode(Document.self, from: Data(contentsOf: file))
            guard document.version == 1, document.entries.count <= Self.entryLimit,
                  Set(document.entries.map(\.id)).count == document.entries.count,
                  document.entries.allSatisfy(Self.valid), document.entries.reduce(0, { $0 + $1.byteCount }) <= Self.byteLimit else {
                throw ClipboardFailure(message: "The saved clipboard history is invalid. It has been left untouched.")
            }
            entries = document.entries
            let fresh = pruned(entries, now: Date())
            if fresh.count != entries.count { try commit(fresh) }
        }
    }
    static func valid(_ entry: ClipboardEntry) -> Bool {
        let allowed = Set(["public.utf8-plain-text", "public.url", "public.rtf", "public.html", "public.png", "public.tiff", "public.file-url"])
        guard !entry.items.isEmpty, entry.items.count <= 50, entry.byteCount > 0, entry.byteCount <= itemByteLimit,
              entry.text.utf8.count <= 1_048_576, entry.source.count <= 256,
              entry.items.allSatisfy({ !$0.isEmpty && Set($0.keys).isSubset(of: allowed) }) else { return false }
        switch entry.kind {
        case .text: return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && entry.items.count == 1 && entry.items[0]["public.utf8-plain-text"] != nil
        case .image: return entry.items.count == 1 && (entry.items[0]["public.png"] != nil || entry.items[0]["public.tiff"] != nil)
        case .files: return entry.fileURLs.count == entry.items.count && entry.fileURLs.allSatisfy(\.isFileURL)
        }
    }
    private func pruned(_ values: [ClipboardEntry], now: Date) -> [ClipboardEntry] {
        values.filter { $0.pinned || now.timeIntervalSince($0.date) < Self.lifetime }
    }
    @discardableResult func add(_ incoming: ClipboardEntry, now: Date = Date()) throws -> UUID {
        guard Self.valid(incoming) else { throw ClipboardFailure(message: "This copy is unsupported or too large to save.") }
        var next = pruned(entries, now: now)
        var item = incoming
        if let index = next.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            var previous = next.remove(at: index)
            previous.date = item.date; previous.source = item.source
            item = previous
        }
        next.insert(item, at: 0)
        while next.count > Self.entryLimit || next.reduce(0, { $0 + $1.byteCount }) > Self.byteLimit {
            guard let index = next.indices.reversed().first(where: { !next[$0].pinned && next[$0].id != item.id }) else {
                throw ClipboardFailure(message: "History is full of pinned items. Unpin or delete an item to save more copies.")
            }
            next.remove(at: index)
        }
        try commit(next)
        return item.id
    }
    func expire(now: Date = Date()) throws {
        let next = pruned(entries, now: now)
        if next.count != entries.count { try commit(next) }
    }
    func togglePin(_ id: UUID) throws {
        var next = entries
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        next[index].pinned.toggle(); try commit(next)
    }
    func remove(_ id: UUID) throws { try commit(entries.filter { $0.id != id }) }
    func clear(keepPinned: Bool) throws { try commit(keepPinned ? entries.filter(\.pinned) : []) }
    private func commit(_ next: [ClipboardEntry]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(Document(version: 1, entries: next))
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        entries = next
    }
}
