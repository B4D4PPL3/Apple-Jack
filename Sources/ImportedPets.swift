import AppKit
import CryptoKit
import ImageIO

// Positioned reads keep concurrent ASAR previews independent and support every Catalina release.
extension FileHandle {
    func petData(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let used = try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) -> Int in
            var used = 0
            while used < count {
                let n = pread(fileDescriptor, bytes.baseAddress!.advanced(by: used), count - used, offset + Int64(used))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if n == 0 { break }
                used += n
            }
            return used
        }
        data.count = used
        return data
    }
}

extension SpriteLoader {
    static func isPetSource(_ source: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(source) as String?, ["public.png", "org.webmproject.webp"].contains(type),
              CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              info[kCGImagePropertyPixelWidth] as? Int == 1536,
              let height = info[kCGImagePropertyPixelHeight] as? Int else { return false }
        return height == 1872 || height == 2288
    }

    static func petImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), isPetSource(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return image
    }

    static func petPreview(_ data: Data) -> CGImage? {
        petImage(data)?.cropping(to: CGRect(x: 0, y: 0, width: 192, height: 208))
    }

    static func importedAtlas(_ data: Data, progress: (Double) -> Void = { _ in }) throws -> [String: LoadedSpriteSheet] {
        let invalid = PetImportError(message: "Choose a ChatGPT pet sprite sheet in PNG or WebP format, 1536 × 1872 or 1536 × 2288 pixels.")
        guard let atlas = petImage(data) else { throw invalid }
        let sheets = try splitAtlas(atlas, progress: progress)
        // A blank animation would make the character disappear when that state plays.
        guard let mask = CGContext(data: nil, width: 192, height: 208, bitsPerComponent: 8, bytesPerRow: 192 * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue), let buffer = mask.data else { throw invalid }
        mask.setBlendMode(.copy)
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        let alphaOffsets = stride(from: 3, to: mask.bytesPerRow * mask.height, by: 4)
        for pose in PetAnimation.allCases {
            for frame in sheets[pose.rawValue]!.frames {
                mask.draw(frame.image, in: CGRect(x: 0, y: 0, width: 192, height: 208))
                guard alphaOffsets.contains(where: { bytes[$0] != 0 }) else {
                    throw PetImportError(message: "The \(pose.rawValue) animation contains an empty frame. Download the complete sprite sheet from ChatGPT and try again.")
                }
            }
        }
        return sheets
    }
}

struct ImportedPet: Equatable {
    let id: String
    let name: String
}

// Use the existing content IDs so pets saved by older releases resolve to the bundled artwork.
enum BundledPet: String, CaseIterable {
    case appleJack = "99afee06221957853f83074c67105835c7e6eef8feb18d1b7aac66640ceaa444"
    case fonz = "59da52d1c0ec269fb7873dcb50e664fabfc7eccfeb0f95d1bda9ff9818302a1d"

    var name: String {
        switch self {
        case .appleJack: return "Apple Jack"
        case .fonz: return "Fonz"
        }
    }

    func load(from resources: URL?, progress: (Double) -> Void) throws -> [String: LoadedSpriteSheet] {
        guard let resources else { throw SpriteLoader.LoadError(name: name) }
        switch self {
        case .appleJack: return try SpriteLoader.load(from: resources, progress: progress)
        case .fonz:
            return try SpriteLoader.loadAtlas(resources.appendingPathComponent("Sprites/FonzPet.png"), petName: name, progress: progress)
        }
    }
}

struct PetImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ImportedPets {
    let directory: URL
    let resources: URL?
    init(directory: URL? = nil, resources: URL? = Bundle.main.resourceURL) {
        let subdirectory = "Apple Jack Public/Pets"
        self.resources = resources
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(subdirectory, isDirectory: true)
    }

    static let limit = 32 * 1024 * 1024
    private static func validID(_ id: String) -> Bool {
        id.utf8.count == 64 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func readFile(_ url: URL, limit: Int = Self.limit) throws -> Data {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw PetImportError(message: "Choose the sprite sheet file downloaded from ChatGPT.") }
        guard let size = info.fileSize, size > 0, size <= limit else { throw PetImportError(message: "Choose a nonempty sprite sheet of 32 MB or less.") }
        let handle = try FileHandle(forReadingFrom: url)
        let data = try handle.petData(at: 0, count: size + 1)
        guard data.count == size else { throw PetImportError(message: "The file changed while it was being read. Try importing it again.") }
        return data
    }

    func contains(_ id: String) -> Bool {
        if BundledPet(rawValue: id) != nil { return true }
        guard Self.validID(id) else { return false }
        let folder = directory.appendingPathComponent(id)
        return ["sheet", "name.txt"].allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    func entries() -> [ImportedPet] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let saved = folders.compactMap { folder -> ImportedPet? in
            let id = folder.lastPathComponent
            guard Self.validID(id), BundledPet(rawValue: id) == nil, let name = try? String(contentsOf: folder.appendingPathComponent("name.txt"), encoding: .utf8) else { return nil }
            return ImportedPet(id: id, name: name)
        }
        // A different pet could already be named Fonz in a library from before Fonz was bundled.
        let reserved = Set(BundledPet.allCases.map { $0.name.lowercased() })
        var used = Set(saved.map { $0.name.lowercased() }).union(reserved)
        return saved.sorted { $0.id < $1.id }.map { pet in
            guard reserved.contains(pet.name.lowercased()) else { return pet }
            let name = Self.availableName(pet.name, used: used)
            used.insert(name.lowercased())
            return ImportedPet(id: pet.id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func availableName(_ stem: String, used: Set<String>) -> String {
        var name = stem, number = 2
        while used.contains(name.lowercased()) { name = "\(stem) (\(number))"; number += 1 }
        return name
    }

    func preview(_ id: String) -> CGImage? {
        let url: URL
        if let bundled = BundledPet(rawValue: id) {
            guard let resources else { return nil }
            let filename = bundled == .appleJack ? "AppleJackPet.png" : "FonzPet.png"
            url = resources.appendingPathComponent("Sprites/" + filename)
            if !FileManager.default.fileExists(atPath: url.path) {
                return (try? bundled.load(from: resources, progress: { _ in }))?[PetAnimation.idle.rawValue]?.frames.first?.image
            }
        } else {
            guard Self.validID(id) else { return nil }
            url = directory.appendingPathComponent(id).appendingPathComponent("sheet")
        }
        guard let data = try? Self.readFile(url) else { return nil }
        return SpriteLoader.petPreview(data)
    }

    func load(_ id: String, progress: (Double) -> Void = { _ in }) throws -> [String: LoadedSpriteSheet] {
        if let pet = BundledPet(rawValue: id) { return try pet.load(from: resources, progress: progress) }
        guard Self.validID(id) else { throw PetImportError(message: "This saved pet is unavailable. Import its sprite sheet again.") }
        return try SpriteLoader.importedAtlas(Self.readFile(directory.appendingPathComponent(id).appendingPathComponent("sheet")), progress: progress)
    }

    func add(from url: URL, named label: String) throws -> (ImportedPet, [String: LoadedSpriteSheet]) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return try add(data: Self.readFile(url), named: name.isEmpty ? url.deletingPathExtension().lastPathComponent : name)
    }

    func add(data: Data, named name: String) throws -> (ImportedPet, [String: LoadedSpriteSheet]) {
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let pet = BundledPet(rawValue: id) {
            return (ImportedPet(id: id, name: pet.name), try pet.load(from: resources, progress: { _ in }))
        }
        let sheets = try SpriteLoader.importedAtlas(data)
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        let saved = entries()
        if let existing = saved.first(where: { $0.id == id }) {
            // Reimport also repairs a missing or damaged local copy.
            try data.write(to: folder.appendingPathComponent("sheet"), options: .atomic)
            return (existing, sheets)
        }

        let proposed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String(proposed.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(80))
        let stem = base.isEmpty ? "Imported Pet" : base
        let used = Set((saved.map(\.name) + BundledPet.allCases.map(\.name)).map { $0.lowercased() })
        let name = Self.availableName(stem, used: used)
        let fm = FileManager.default
        let stage = directory.appendingPathComponent(".import-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        try data.write(to: stage.appendingPathComponent("sheet"))
        try name.write(to: stage.appendingPathComponent("name.txt"), atomically: false, encoding: .utf8)
        try fm.moveItem(at: stage, to: folder)
        return (ImportedPet(id: id, name: name), sheets)
    }

    func remove(_ pet: ImportedPet) throws {
        guard Self.validID(pet.id), BundledPet(rawValue: pet.id) == nil else { throw PetImportError(message: "This saved pet is unavailable.") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(pet.id))
    }
}
