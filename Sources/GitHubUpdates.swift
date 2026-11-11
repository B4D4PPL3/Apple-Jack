import CryptoKit
import Foundation

enum GitHubUpdates {
    static func repositoryURL(_ name: String?) throws -> URL {
        guard let name, !name.isEmpty else { throw UpdateError.missingRepository }
        let parts = name.components(separatedBy: "/")
        guard parts.count == 2, parts.allSatisfy({
            $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        }) else { throw UpdateError.invalidRelease }
        return URL(string: "https://github.com/")!.appendingPathComponent(name)
    }

    private static func repository() throws -> URL {
        try repositoryURL(Bundle.main.object(forInfoDictionaryKey: "AppleJackGitHubRepository") as? String)
    }

    private static func validate(_ response: URLResponse, limit: Int64) throws {
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https" else {
            throw UpdateError.invalidRelease
        }
        if response.statusCode == 404 { throw UpdateError.missingRelease }
        guard response.statusCode == 200, response.expectedContentLength <= limit else {
            throw UpdateError.invalidRelease
        }
    }

    static func check() async throws -> UpdateRelease {
        let url = try manifestURL(in: repository())
        return try await check(url: url, session: .shared)
    }

    static func manifestURL(in repository: URL) -> URL {
        URL(string: "https://raw.githubusercontent.com")!.appendingPathComponent(repository.path)
            .appendingPathComponent("main/Updates/latest.json")
    }

    static func feedURL(in repository: URL) -> URL {
        manifestURL(in: repository).deletingLastPathComponent().appendingPathComponent("appcast.xml")
    }

    static func check(url: URL, session: URLSession) async throws -> UpdateRelease {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let (bytes, response) = try await session.bytes(for: request)
        try validate(response, limit: 65_536)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw UpdateError.invalidRelease }
            data.append(byte)
        }
        return try UpdateRelease.decode(data)
    }

    static func assetURL(for release: UpdateRelease, in repo: URL) -> URL {
        // Use the versioned asset even if a new latest release appears mid-update.
        repo.appendingPathComponent("releases/download/" + (release.releaseTag ?? "v" + release.version)).appendingPathComponent(release.file)
    }

    static func download(_ release: UpdateRelease) async throws -> URL {
        let url = try assetURL(for: release, in: repository())
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validate(response, limit: 1_073_741_824)
        return try await Task.detached(priority: .utility) {
            try verifiedImage(temporary, release: release)
        }.value
    }

    static func verifiedImage(_ input: URL, release: UpdateRelease) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("AppleJackPublicUpdate-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let url = directory.appendingPathComponent(release.file)
            try manager.moveItem(at: input, to: url)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            guard (512...1_073_741_824).contains(length) else { throw UpdateError.invalidInstaller }
            try handle.seek(toOffset: length - 512)
            guard try handle.read(upToCount: 4) == Data("koly".utf8) else { throw UpdateError.invalidInstaller }
            try handle.seek(toOffset: 0)
            var hash = SHA256()
            while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
                hash.update(data: block)
            }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == release.sha256.lowercased() else { throw UpdateError.checksumMismatch }
            return url
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}
