import AppKit
import ImageIO

struct ChatGPTPetCandidate {
    var id: String? = nil
    let name: String
    let sourceName: String
    let data: () throws -> Data

    func preview() -> CGImage? {
        guard let data = try? data(), let source = CGImageSourceCreateWithData(data as CFData, nil),
              SpriteLoader.isPetSource(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 208))
    }
}

enum ChatGPTPetCatalog {
    private struct Manifest: Decodable {
        let id: String?
        let displayName: String?
        let spritesheetPath: String?
    }

    static func installed() -> [ChatGPTPetCandidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots = [home.appendingPathComponent(".codex")]
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], configured.hasPrefix("/") {
            roots.insert(URL(fileURLWithPath: configured, isDirectory: true), at: 0)
        }
        let workspace = NSWorkspace.shared
        let apps = ["com.openai.codex", "com.openai.chat"].compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            + [home.appendingPathComponent("Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/ChatGPT.app")]
        return scan(roots: roots, apps: apps)
    }

    static func scan(roots: [URL], apps: [URL]) -> [ChatGPTPetCandidate] {
        var packages: [String: ChatGPTPetCandidate] = [:]
        var builtIns: [String: ChatGPTPetCandidate] = [:]
        for root in distinct(roots) {
            // The current package wins over an older avatar with the same folder ID.
            for (subdir, filename) in [("pets", "pet.json"), ("avatars", "avatar.json")] {
                guard let directory = PetDiscoveryAccess.allowedURL(root.appendingPathComponent(subdir, isDirectory: true)) else { continue }
                let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [], options: [.skipsHiddenFiles])) ?? []
                for folder in folders where packages[folder.lastPathComponent] == nil {
                    packages[folder.lastPathComponent] = package(folder, manifestName: filename)
                }
            }
        }
        for app in distinct(apps) {
            guard let resource = PetDiscoveryAccess.allowedURL(app.appendingPathComponent("Contents/Resources/app.asar", isDirectory: false)),
                  let archive = try? PetAssetArchive(url: resource) else { continue }
            for (slug, entry) in archive.sheets where builtIns[slug] == nil {
                let title = slug == "bsod" ? "BSOD" : slug.replacingOccurrences(of: "-", with: " ").capitalized
                builtIns[slug] = ChatGPTPetCandidate(id: "builtin:" + slug, name: title, sourceName: "Built-in") { try archive.read(entry) }
            }
        }
        let sorted: ([String: ChatGPTPetCandidate]) -> [ChatGPTPetCandidate] = { items in
            items.sorted { lhs, rhs in
                let order = lhs.value.name.localizedStandardCompare(rhs.value.name)
                return order == .orderedSame ? lhs.key < rhs.key : order == .orderedAscending
            }.map(\.value)
        }
        return sorted(packages) + sorted(builtIns)
    }

    static func merged(local: [ChatGPTPetCandidate], account: [ChatGPTPetCandidate]) -> [ChatGPTPetCandidate] {
        let localIDs = Set(local.compactMap(\.id))
        let missing = account.filter { !localIDs.contains($0.id ?? "") }
        return missing.filter { $0.sourceName == "ChatGPT" } + local + missing.filter { $0.sourceName == "Built-in" }
    }

    private static func distinct(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap(PetDiscoveryAccess.allowedURL).filter { seen.insert($0.path).inserted }
    }

    private static func child(_ path: String, of folder: URL) -> URL? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        guard let url = PetDiscoveryAccess.allowedURL(folder.appendingPathComponent(path, isDirectory: false)) else { return nil }
        return url.path.hasPrefix(folder.path + "/") ? url : nil
    }

    private static func package(_ url: URL, manifestName: String) -> ChatGPTPetCandidate? {
        guard let folder = PetDiscoveryAccess.allowedURL(url),
              let json = child(manifestName, of: folder),
              let bytes = try? ImportedPets.readFile(json, limit: 131_072),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes) else { return nil }
        let path = manifest.spritesheetPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "spritesheet.webp"
        guard let sheet = child(path, of: folder), let info = try? sheet.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize, size > 0, size <= ImportedPets.limit,
              let image = CGImageSourceCreateWithURL(sheet as CFURL, nil), SpriteLoader.isPetSource(image) else { return nil }
        let title = [manifest.displayName, manifest.id, url.lastPathComponent].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? url.lastPathComponent
        return ChatGPTPetCandidate(id: manifest.id ?? url.lastPathComponent, name: String(title.prefix(100)), sourceName: "Custom") {
            guard let current = child(path, of: folder) else { throw PetImportError(message: "This pet’s sprite sheet has moved. Open the pet list again.") }
            return try ImportedPets.readFile(current)
        }
    }
}

// Electron ASAR has a length-prefixed JSON file table followed by the packed files.
// Keep the read-only descriptor for this snapshot so a ChatGPT update can't change its offsets.
private final class PetAssetArchive {
    struct Entry {
        let offset: UInt64
        let size: Int
    }
    private let file: FileHandle
    private let lock = NSLock()
    let sheets: [String: Entry]

    init(url: URL) throws {
        let invalid = PetImportError(message: "Couldn’t read pet artwork in this installation of ChatGPT.")
        let handle = try FileHandle(forReadingFrom: url)
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let prefix = try handle.read(upToCount: 16) ?? Data()
        guard prefix.count == 16 else { throw invalid }
        func word(_ i: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(prefix[i + $1]) << (8 * $1) }
        }
        let headerSize = word(4), jsonSize = word(12)
        let base = UInt64(headerSize + 8)
        guard word(0) == 4, jsonSize > 0, headerSize >= 8 + jsonSize, headerSize <= 32 * 1024 * 1024, base <= fileSize,
              let bytes = try handle.read(upToCount: jsonSize), bytes.count == jsonSize,
              let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw invalid }
        var node = root
        for component in ["webview", "assets"] {
            guard let files = node["files"] as? [String: Any], let child = files[component] as? [String: Any] else { throw invalid }
            node = child
        }
        guard let assets = node["files"] as? [String: Any] else { throw invalid }
        var sheets: [String: Entry] = [:]
        let sprites = assets.keys.filter { $0.contains("-spritesheet") }
        for filename in sprites.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending }) {
            guard filename.hasSuffix(".webp") || filename.hasSuffix(".png"),
                  let marker = filename.range(of: "-spritesheet"), marker.lowerBound > filename.startIndex,
                  let item = assets[filename] as? [String: Any],
                  let length = item["size"] as? Int, length > 0, length <= ImportedPets.limit,
                  let raw = item["offset"] as? String, let relative = UInt64(raw), relative <= fileSize - base,
                  UInt64(length) <= fileSize - base - relative else { continue }
            let slug = String(filename[..<marker.lowerBound])
            if sheets[slug] == nil { sheets[slug] = Entry(offset: base + relative, size: length) }
        }
        self.file = handle
        self.sheets = sheets
    }

    func read(_ entry: Entry) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        try file.seek(toOffset: entry.offset)
        guard let data = try file.read(upToCount: entry.size), data.count == entry.size else {
            throw PetImportError(message: "This pet’s artwork is unavailable. Reopen the list to scan again.")
        }
        return data
    }
}
