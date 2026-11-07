import Foundation
import CryptoKit
import Darwin

enum UpdateChannel: String {
    case stable
    var title: String { "Stable" }
}

struct UpdateRelease: Codable {
    let schemaVersion: Int
    let bundleIdentifier: String
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let architecture: String
    let file: String
    let sha256: String
    let notes: String
    let channel: String?

    var releaseChannel: UpdateChannel { UpdateChannel(rawValue: channel ?? "stable") ?? .stable }

    static let bundleIdentifier = "com.fonz.applejack.public"
    static let architectureName = "universal"

    static func decode(_ data: Data) throws -> UpdateRelease {
        guard data.count <= 65_536 else { throw UpdateError.invalidRelease }
        guard let release = try? JSONDecoder().decode(UpdateRelease.self, from: data) else {
            throw UpdateError.invalidRelease
        }
        guard release.schemaVersion == 1,
              release.bundleIdentifier == Self.bundleIdentifier,
              release.version.count < 80, systemVersionParts(release.version) != nil,
              release.build > 0, release.architecture == Self.architectureName,
              release.channel == UpdateChannel.stable.rawValue,
              systemVersionParts(release.minimumSystemVersion) != nil,
              !release.file.isEmpty, release.file.count < 240,
              release.file == (release.file as NSString).lastPathComponent,
              !release.file.contains("\\"), !release.file.hasPrefix("."),
              release.file == "Apple-Jack-\(release.version)-macOS.dmg",
              release.file.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              release.sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil,
              release.notes.count <= 8_000 else { throw UpdateError.invalidRelease }
        return release
    }

    func isNewer(than installedBuild: Int) -> Bool { build > installedBuild }

    func supports(_ system: OperatingSystemVersion) -> Bool {
        guard let required = Self.systemVersionParts(minimumSystemVersion) else { return false }
        let installed = [system.majorVersion, system.minorVersion, system.patchVersion]
        for (have, need) in zip(installed, required) where have != need { return have > need }
        return true
    }

    private static func systemVersionParts(_ value: String) -> [Int]? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        let numbers = pieces.compactMap { Int($0) }
        guard numbers.count == pieces.count, numbers.allSatisfy({ $0 >= 0 }) else { return nil }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }
}

enum UpdateError: LocalizedError {
    case invalidRelease, missingRelease, missingRepository, checksumMismatch, invalidInstaller

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "The update information does not match this edition of Apple Jack."
        case .missingRelease: return "There is no published Apple Jack release at the configured GitHub repository yet."
        case .missingRepository: return "This local build has no GitHub release address yet."
        case .checksumMismatch: return "The downloaded installer failed its checksum check. Please try again."
        case .invalidInstaller: return "The downloaded file is not a valid Apple Jack disk image."
        }
    }
}
