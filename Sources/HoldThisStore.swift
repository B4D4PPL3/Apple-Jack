import AppKit
import ImageIO

struct HeldItem: Codable, Identifiable {
    enum Kind: String, Codable { case file, image, link, text }
    let id: UUID
    let kind: Kind
    let value: String
    var bookmark: Data? = nil
    var payloadFolder: UUID? = nil
    var imageType: String? = nil
    var pinned: Bool? = nil   // Absent in shelves saved before pinning was introduced.
    var isPinned: Bool { pinned == true }

    var title: String {
        switch kind {
        case .file, .image: return (value as NSString).lastPathComponent
        case .link: return value
        case .text: return String(value.split(whereSeparator: \.isNewline).first?.prefix(160) ?? "Text")
        }
    }

    var websiteURL: URL? {
        guard kind == .link, let url = URL(string: value), HeldWebsitePreview.isWebsite(url) else { return nil }
        return url
    }

    func temporaryTextDocument() throws -> URL {
        // Quick Look needs a local URL. A fresh system-managed temporary document
        // can also be opened in an editor without overwriting an earlier copy.
        let manager = FileManager.default
        let directory = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: manager.temporaryDirectory, create: true)
        let url = directory.appendingPathComponent(kind == .link ? "Held Link.txt" : "Held Text.txt")
        try value.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

final class HoldThisStore {
    static let removeKey = "holdThisRemoveAfterDrag"
    static var removesAfterDrag: Bool {
        get { (UserDefaults.standard.object(forKey: removeKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: removeKey) }
    }
    static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"), (.init("public.jpeg"), "jpg"), (.init("com.compuserve.gif"), "gif"),
        (.init("public.heic"), "heic"), (.init("org.webmproject.webp"), "webp"), (.tiff, "tiff")
    ]
    static let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    static var dropTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .rtf] + imageTypes.map(\.0) + promiseTypes
    }

    private struct Archive: Codable { let version: Int; let items: [HeldItem] }
    private let directory: URL
    private var payloads: URL { directory.appendingPathComponent("Payloads", isDirectory: true) }
    private var index: URL { directory.appendingPathComponent("Items.plist") }
    private let deliveryQueue = OperationQueue()
    private(set) var items: [HeldItem] = []
    private(set) var loadError: Error?
    var changed: (() -> Void)?
    var deliveryError: ((Error) -> Void)?

    init(directory: URL? = nil) {
        let product = "Apple Jack Public"
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(product).appendingPathComponent("Hold This", isDirectory: true)
        deliveryQueue.maxConcurrentOperationCount = 1
        do {
            if FileManager.default.fileExists(atPath: index.path) {
                let archive = try PropertyListDecoder().decode(Archive.self, from: Data(contentsOf: index))
                guard archive.version == 1 else { throw Self.error("This Hold This library requires a newer version of Jack.") }
                items = archive.items
            }
            discardExpiredPayloads()
        } catch { loadError = error }
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "AppleJack.HoldThis", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func commit(_ next: [HeldItem]) throws {
        if let loadError { throw loadError }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(Archive(version: 1, items: next)).write(to: index, options: .atomic)
        items = next
        changed?()
    }
    func togglePin(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items
        next[index].pinned = !items[index].isPinned
        try commit(next)
    }

    func releaseAfterDrag(_ ids: Set<UUID>) throws {
        try remove(ids.subtracting(items.filter(\.isPinned).map(\.id)))
    }

    func remove(_ ids: Set<UUID>) throws {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        let removedFolders = Set(items.filter { ids.contains($0.id) }.compactMap(\.payloadFolder))
        // Give the receiving app time to finish reading the outgoing file URL.
        for folder in removedFolders {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: payloads.appendingPathComponent(folder.uuidString).path)
        }
        try commit(items.filter { !ids.contains($0.id) })
    }
    private func discardExpiredPayloads() {
        let inUse = Set(items.compactMap { $0.payloadFolder?.uuidString })
        let folders = (try? FileManager.default.contentsOfDirectory(at: payloads, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil && !inUse.contains(folder.lastPathComponent) {
            if let date = try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date.timeIntervalSinceNow < -86400 { try? FileManager.default.removeItem(at: folder) }
        }
    }
    private func makePayloadFolder(_ id: UUID) throws -> URL {
        let folder = payloads.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }
    func fileURL(for item: HeldItem) -> URL? {
        guard item.kind == .file || item.kind == .image else { return nil }
        if let folder = item.payloadFolder {
            let name = item.value
            guard !name.isEmpty, name != ".", name != "..", name == (name as NSString).lastPathComponent else { return nil }
            return payloads.appendingPathComponent(folder.uuidString).appendingPathComponent(name)
        }
        var stale = false
        if let bookmark = item.bookmark, let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) { return resolved }
        return URL(fileURLWithPath: item.value)
    }
    func previewURL(for item: HeldItem) throws -> URL {
        switch item.kind {
        case .text, .link:
            if let website = item.websiteURL { return website }
            return try item.temporaryTextDocument()
        case .file, .image:
            guard let url = fileURL(for: item), FileManager.default.fileExists(atPath: url.path) else {
                throw Self.error("The original file “\(item.title)” is unavailable on this Mac.")
            }
            return url
        }
    }

    func writer(for item: HeldItem) -> NSPasteboardItem? {
        let writer = NSPasteboardItem()
        switch item.kind {
        case .file, .image:
            guard let url = fileURL(for: item), FileManager.default.fileExists(atPath: url.path) else { return nil }
            writer.setString(url.absoluteString, forType: .fileURL)
            if let rawType = item.imageType, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                writer.setData(data, forType: .init(rawType))
            }
        case .link:
            writer.setString(item.value, forType: .URL)
            writer.setString(item.value, forType: .string)
        case .text:
            writer.setString(item.value, forType: .string)
        }
        return writer
    }

    func accept(_ board: NSPasteboard) throws {
        if let loadError { throw loadError }
        var additions: [HeldItem] = []
        let batch = UUID()
        var promisedDestination: URL?
        var receivers: [NSFilePromiseReceiver] = []
        let values = board.pasteboardItems ?? []
        let promiseItems = values.filter { $0.types.contains(where: Self.promiseTypes.contains) }
        let offered = promiseItems.isEmpty ? [] : board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        var promises = offered.makeIterator()
        do {
            for value in values {
                let isPromise = value.types.contains(where: Self.promiseTypes.contains)
                let receiver = isPromise ? promises.next() : nil
                if let string = value.string(forType: .fileURL), let url = URL(string: string), url.isFileURL {
                    let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    additions.append(HeldItem(id: UUID(), kind: .file, value: url.path, bookmark: bookmark))
                } else if let (type, ext) = Self.imageTypes.first(where: { value.types.contains($0.0) }),
                          let data = value.data(forType: type), let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
                    let folder = try makePayloadFolder(batch)
                    let name = "Image " + UUID().uuidString.prefix(8) + "." + ext
                    try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                    additions.append(HeldItem(id: UUID(), kind: .image, value: name, payloadFolder: batch, imageType: type.rawValue))
                } else if isPromise, !value.types.contains(.URL) || receiver?.fileTypes.contains(where: { type in
                    (CGImageSourceCopyTypeIdentifiers() as? [String])?.contains(type) == true
                }) == true {
                    guard let receiver, promiseItems.count == offered.count else {
                        throw Self.error("The source app didn’t provide the promised file.")
                    }
                    receivers.append(receiver)
                } else if let link = value.string(forType: .URL), let url = URL(string: link), url.scheme != nil {
                    additions.append(HeldItem(id: UUID(), kind: .link, value: url.absoluteString))
                } else if let text = value.string(forType: .string) ?? value.data(forType: .rtf).flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil)?.string }),
                          !text.isEmpty {
                    let url = URL(string: text)
                    let isLink = ["https", "http"].contains(url?.scheme?.lowercased()) && url?.host != nil && !text.contains(where: \.isWhitespace)
                    additions.append(HeldItem(id: UUID(), kind: isLink ? .link : .text, value: text))
                } else { throw Self.error("Jack couldn’t read one of the dragged items.") }
            }
            if !receivers.isEmpty {
                promisedDestination = try makePayloadFolder(UUID())
            }
            guard !additions.isEmpty || !receivers.isEmpty else { throw Self.error("Drop a file, image, link, or text onto Jack.") }
            if !additions.isEmpty { try commit(additions + items) }
        } catch {
            try? FileManager.default.removeItem(at: payloads.appendingPathComponent(batch.uuidString))
            throw error
        }
        if let folder = promisedDestination, let folderID = UUID(uuidString: folder.lastPathComponent) {
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: deliveryQueue) { [weak self] url, error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        do {
                            if let error { throw error }
                            guard url.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path,
                                  FileManager.default.fileExists(atPath: url.path) else { throw Self.error("The promised file was unavailable.") }
                            let item = HeldItem(id: UUID(), kind: .file, value: url.lastPathComponent, payloadFolder: folderID)
                            try self.commit([item] + self.items)
                        } catch { self.deliveryError?(error) }
                    }
                }
            }
        }
    }
}
