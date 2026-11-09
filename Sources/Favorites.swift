import AppKit

struct JackFavorite: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case app, folder, website, shortcut, item
        static var addable: [Self] {
            return [.app, .folder, .website, .shortcut]
        }
        var title: String {
            switch self { case .app: return "App"; case .folder: return "Folder"; case .website: return "Website"; case .shortcut: return "Shortcut"; case .item: return "Item" }
        }
        var symbol: String {
            switch self { case .app: return "app"; case .folder: return "folder"; case .website: return "globe"; case .shortcut: return "square.stack.3d.up"; case .item: return "doc" }
        }
    }
    let id: UUID
    let kind: Kind
    var name: String
    let destination: String
    let bookmark: Data?
    let bundleIdentifier: String?

    static func make(id: UUID = UUID(), kind: Kind, name: String, destination: String) throws -> JackFavorite {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.count <= 120, !label.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw failure("Enter a name from 1 to 120 characters on one line.")
        }
        guard !target.isEmpty, target.count <= 8192, !target.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw failure("Enter a destination on one line.")
        }
        switch kind {
        case .website:
            guard case .website(let url, _) = LocationOpenRequest.parse(target) else {
                throw failure("Enter a website such as apple.com or https://example.com. Websites open in Safari.")
            }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
            return JackFavorite(id: id, kind: kind, name: label, destination: parts.url!.absoluteString, bookmark: nil, bundleIdentifier: nil)
        case .shortcut:
            guard !target.hasPrefix("-"), target.count <= 512 else {
                throw failure("Enter the shortcut’s exact name, without command-line options.")
            }
            return JackFavorite(id: id, kind: kind, name: label, destination: target, bookmark: nil, bundleIdentifier: nil)
        case .app, .folder, .item:
            guard case .finder(let url) = LocationOpenRequest.parse(target) else {
                throw failure("Choose an app or folder, or enter its full Finder path.")
            }
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let values = try canonical.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if kind == .app {
                guard InstalledApp(url: canonical) != nil else { throw failure("Choose an installed .app application.") }
            } else if kind == .folder {
                guard values.isDirectory == true, values.isPackage != true else { throw failure("Choose a folder rather than a file or app.") }
            }
            let bookmark = try? canonical.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return JackFavorite(id: id, kind: kind, name: label, destination: canonical.path, bookmark: bookmark,
                                bundleIdentifier: kind == .app ? Bundle(url: canonical)?.bundleIdentifier : nil)
        }
    }
    var localURL: URL {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return resolved
            }
        }
        return URL(fileURLWithPath: destination)
    }
    static func failure(_ message: String) -> Error {
        NSError(domain: "AppleJack.Favorites", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

final class FavoritesStore {
    // Older builds read the same two entry archives. The newest archive also
    // records the combined row order, so a reorder needs one atomic write.
    private struct Archive: Codable {
        let schemaVersion: Int
        let entries: [JackFavorite]
        var order: [UUID]?
        var revision: UInt64?
    }
    private var revision: UInt64 = 0
    static let limit = 100
    private(set) var entries: [JackFavorite] = []
    private(set) var loadError: String?
    let file: URL
    var didChange: (() -> Void)?

    static let relativePath = "Apple Jack Public/Favorites.json"
    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(FavoritesStore.relativePath)) {
        self.file = file
        // Keep ordinary favorites readable and editable by earlier releases on this Mac.
        do {
            var order = [UUID]()
            for file in [file, itemsFile] where FileManager.default.fileExists(atPath: file.path) {

                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 2_000_000 else { throw JackFavorite.failure("The favorites file is too large.") }
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.schemaVersion == 1, archive.entries.count <= Self.limit,
                      Set(archive.entries.map(\.id)).count == archive.entries.count,
                      archive.entries.allSatisfy(Self.validStoredEntry) else {
                    throw JackFavorite.failure("The favorites file has an unsupported format.")
                }
                guard archive.entries.allSatisfy({ ($0.kind == .item) == (file == itemsFile) }),
                      Set(entries.map(\.id)).isDisjoint(with: archive.entries.map(\.id)) else { throw JackFavorite.failure("Invalid favorite category or ID.") }
                entries += archive.entries
                if let version = archive.revision, version > revision, let ids = archive.order {
                    revision = version
                    order = ids
                }
            }
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            var seen = Set<UUID>()
            entries = order.filter { seen.insert($0).inserted }.compactMap { byID[$0] } + entries.filter { !seen.contains($0.id) }
        } catch { loadError = "Couldn’t load Favorites. Your saved file has been left unchanged. \(error.localizedDescription)" }
    }
    private var itemsFile: URL { file.deletingPathExtension().appendingPathExtension("items.json") }
    private static func validStoredEntry(_ entry: JackFavorite) -> Bool {
        guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              entry.name.count <= 120, !entry.name.contains(where: { $0.isNewline || $0 == "\0" }),
              !entry.destination.isEmpty, entry.destination.count <= 8192,
              !entry.destination.contains(where: { $0.isNewline || $0 == "\0" }),
              (entry.bookmark?.count ?? 0) <= 262_144 else { return false }
        switch entry.kind {
        case .website:
            guard case .website = LocationOpenRequest.parse(entry.destination) else { return false }; return true
        case .shortcut: return !entry.destination.hasPrefix("-") && entry.destination.count <= 512
        case .app, .folder, .item: return entry.destination.hasPrefix("/")
        }
    }
    func save(_ entry: JackFavorite) throws {
        guard Self.validStoredEntry(entry) else { throw JackFavorite.failure("This favorite has an invalid name or destination.") }
        guard !entries.contains(where: { $0.id != entry.id && $0.kind == entry.kind && $0.destination == entry.destination }) else {
            throw JackFavorite.failure("That destination is already in Favorites. Edit the existing favorite to rename it.")
        }
        var next = entries
        if let index = next.firstIndex(where: { $0.id == entry.id }) { next[index] = entry }
        else {
            guard next.count < Self.limit else { throw JackFavorite.failure("Favorites holds up to \(Self.limit) items. Remove one before adding another.") }
            next.append(entry)
        }
        try commit(next, items: entry.kind == .item)
    }
    func remove(id: UUID) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        try commit(entries.filter { $0.id != id }, items: entry.kind == .item)
        let folder = ownedFolder(for: id)
        if URL(fileURLWithPath: entry.destination).deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: folder)
        }
    }
    func canMove(id: UUID, by offset: Int) -> Bool {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries.indices.contains(i + offset) else { return false }
        return true
    }
    func ownedFolder(for id: UUID) -> URL {
        file.deletingLastPathComponent().appendingPathComponent("Favorite Payloads", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func move(id: UUID, by offset: Int) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), canMove(id: id, by: offset) else { return }
        var next = entries; next.swapAt(index, index + offset); try commit(next, items: entries[index].kind == .item)
    }
    func move(id: UUID, before target: UUID?) throws {
        guard id != target, let entry = entries.first(where: { $0.id == id }) else { return }
        var next = entries.filter { $0.id != id }
        let index = target.flatMap { target in next.firstIndex { $0.id == target } } ?? next.endIndex
        next.insert(entry, at: index)
        if next.map(\.id) != entries.map(\.id) { try commit(next, items: entry.kind == .item) }
    }
    private func commit(_ next: [JackFavorite], items: Bool) throws {
        if let loadError { throw JackFavorite.failure(loadError) }
        let file = items ? itemsFile : self.file
        let data = try JSONEncoder().encode(Archive(schemaVersion: 1, entries: next.filter { ($0.kind == .item) == items },
                                                   order: next.map(\.id), revision: revision + 1))
        guard data.count <= 2_000_000 else { throw JackFavorite.failure("Favorites has reached its storage limit.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        revision += 1
        entries = next
        didChange?()
    }
}
