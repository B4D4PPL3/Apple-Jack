import Foundation
import CryptoKit

private final class ReleaseProtocol: URLProtocol {
    static var status = 200
    static var data = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum PublicUpdateChecks {
    static func expectFailure(_ check: () throws -> Void) {
        do { try check(); preconditionFailure("Invalid update was accepted") } catch {}
    }

    static func main() async throws {
        expectFailure { _ = try GitHubUpdates.repositoryURL(nil) }
        for invalid in ["https://elsewhere.test/x", "../escape", "owner/repo?x", "/owner/repo", "owner/repo/../repo"] {
            expectFailure { _ = try GitHubUpdates.repositoryURL(invalid) }
        }
        let repo = try GitHubUpdates.repositoryURL("example/apple-jack")
        let url = repo.appendingPathComponent("releases/latest/download/latest.json")
        var image = Data("koly".utf8)
        image.append(Data(repeating: 0, count: 508))
        let digest = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        var manifest: [String: Any] = ["schemaVersion":1,"bundleIdentifier":"com.fonz.applejack.public","version":"0.52","build":115,
            "minimumSystemVersion":"13.0","architecture":"universal","channel":"stable","notes":"A new stable release.",
            "file":"Apple-Jack-0.52-macOS.dmg","sha256":digest]
        func encoded() throws -> Data { try JSONSerialization.data(withJSONObject: manifest) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReleaseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        ReleaseProtocol.data = try encoded()
        let release = try await GitHubUpdates.check(url:url,session:session)
        precondition(release.isNewer(than:114) && !release.isNewer(than:115))
        precondition(GitHubUpdates.assetURL(for:release,in:repo).absoluteString == "https://github.com/example/apple-jack/releases/download/v0.52/Apple-Jack-0.52-macOS.dmg")
        ReleaseProtocol.status = 404
        do { _ = try await GitHubUpdates.check(url:url,session:session); preconditionFailure() } catch UpdateError.missingRelease {}
        for (key,bad) in [("channel","beta"), ("bundleIdentifier","com.fonz.applejack.desktop"), ("file","../evil.dmg"), ("architecture","arm64")] {
            let good = manifest[key]
            manifest[key] = bad
            expectFailure { _ = try UpdateRelease.decode(encoded()) }
            manifest[key] = good
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try image.write(to:scratch)
        let verified = try GitHubUpdates.verifiedImage(scratch,release:release)
        defer { try? FileManager.default.removeItem(at:verified.deletingLastPathComponent()) }
        let result = try Data(contentsOf:verified)
        precondition(result == image)
        image[511] = 1
        try image.write(to:scratch)
        expectFailure { _ = try GitHubUpdates.verifiedImage(scratch,release:release) }
        print("PASS GitHub release selection, unmapped local build, missing release, private/beta rejection, installer filename, digest, and altered download checks.")
    }
}
