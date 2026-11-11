import AppKit
import CryptoKit

@main struct Checks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw PetImportError(message: message) }
    }
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("jack-companions-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let library = ImportedPets(directory: temp, resources: resources)
        try require(BundledPet.allCases.map(\.name) == ["Apple Jack", "Apple Jack (Classic)", "Fonz"], "Wrong built-in order")
        for pet in BundledPet.allCases {
            let data = try Data(contentsOf: resources.appendingPathComponent("Sprites/" + pet.spriteFilename))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try require(hash == pet.rawValue && library.contains(hash), "Artwork identity mismatch")
            let frames = try library.load(hash)
            // The importer validates nonempty animation frames independently of bundled loading.
            _ = try SpriteLoader.importedAtlas(data)
            try require(frames.count == 9 && PetAnimation.allCases.allSatisfy { frames[$0.rawValue]?.frameCount == $0.count }, "Incomplete animations")
            try require(library.preview(hash) != nil, "Missing built-in preview")
            let (same, _) = try library.add(data: data, named: "Old imported name")
            try require(same.name == pet.name && same.id == hash && library.entries().isEmpty && !fm.fileExists(atPath: temp.path), "Import duplicated built-in")
            let folder = temp.appendingPathComponent(hash)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try "AppleJack Pixel".write(to: folder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
            try Data([0]).write(to: folder.appendingPathComponent("sheet"))
            try require(library.entries().isEmpty && library.preview(hash) != nil, "Old saved entry was not resolved to bundled artwork")
            _ = try library.load(hash)
            var blocked = false
            do { try library.remove(same) } catch { blocked = true }
            try require(blocked && fm.fileExists(atPath: folder.path), "Built-in was removable")
            try fm.removeItem(at: temp)
            print("PASS \(pet.name): offline load, 57 nonempty frames, preview, reimport deduplication, old saved ID and removal protection")
        }
        let customID = String(repeating: "a", count: 64)
        let customFolder = temp.appendingPathComponent(customID)
        try fm.createDirectory(at: customFolder, withIntermediateDirectories: true)
        try "Apple Jack (Classic)".write(to: customFolder.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        try require(library.entries() == [ImportedPet(id: customID, name: "Apple Jack (Classic) (2)")], "Distinct custom companion name collided with built-in")
        print("PASS distinct imported names remain available separately from the three built-ins")
    }
}
