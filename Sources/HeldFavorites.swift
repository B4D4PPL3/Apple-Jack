import AppKit

extension FavoritesStore {
    func addHeld(_ item: HeldItem, from shelf: HoldThisStore) throws {
        if let loadError { throw JackFavorite.failure(loadError) }
        guard !entries.contains(where: { $0.id == item.id }) else { throw JackFavorite.failure("This item is already in Favorites.") }
        guard entries.count < Self.limit else { throw JackFavorite.failure("Favorites is full. Remove an entry before adding another.") }
        func label(_ value: String) -> String {
            let text = value.components(separatedBy: .controlCharacters).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Held Item" : String(text.prefix(120))
        }
        if let url = item.websiteURL {
            try save(JackFavorite.make(id: item.id, kind: .website, name: label(item.title), destination: url.absoluteString))
            return
        }
        if item.kind == .link, let link = URLComponents(string: item.value), link.scheme?.lowercased() == "shortcuts",
           link.host?.lowercased() == "run-shortcut", link.queryItems?.count == 1, let query = link.queryItems?.first,
           query.name == "name", let name = query.value {
            try save(JackFavorite.make(id: item.id, kind: .shortcut, name: label(name), destination: name))
            return
        }

        let folder = ownedFolder(for: item.id)
        var created = false
        do {
            let source = shelf.fileURL(for: item)
            if source == nil && (item.kind == .image || item.kind == .file) { throw CocoaError(.fileNoSuchFile) }
            if let source, !FileManager.default.fileExists(atPath: source.path) { throw CocoaError(.fileNoSuchFile) }
            let url: URL
            if let source, item.payloadFolder == nil {
                url = source
            } else {
                // Shelf-owned files may expire after dragging out. Own a separate copy before saving.
                let fm = FileManager.default
                try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                created = true
                if let source {
                    url = folder.appendingPathComponent(source.lastPathComponent)
                    try fm.copyItem(at: source, to: url)
                } else {
                    url = folder.appendingPathComponent(item.kind == .link ? "Link.webloc" : "Note.txt")
                    let data = item.kind == .link
                        ? try PropertyListSerialization.data(fromPropertyList: ["URL": item.value], format: .xml, options: 0)
                        : Data(item.value.utf8)
                    try data.write(to: url, options: .atomic)
                }
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let kind: JackFavorite.Kind
            if url.pathExtension.lowercased() == "app", InstalledApp(url: url) != nil { kind = .app }
            else if values.isDirectory == true && values.isPackage != true { kind = .folder }
            else { kind = .item }
            let name = kind == .app ? url.deletingPathExtension().lastPathComponent : item.title
            try save(JackFavorite.make(id: item.id, kind: kind, name: label(name), destination: url.path))
        } catch {
            if created { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
    }
}
