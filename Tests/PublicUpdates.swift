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
        let url = GitHubUpdates.manifestURL(in: repo)
        precondition(url.absoluteString == "https://raw.githubusercontent.com/example/apple-jack/main/Updates/latest.json")
        precondition(GitHubUpdates.feedURL(in: repo).absoluteString == "https://raw.githubusercontent.com/example/apple-jack/main/Updates/appcast.xml")
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
        expectFailure { try release.requireSparkleSignature() }
        manifest["releaseTag"] = "v0.52-preview.1"
        manifest["file"] = "Apple-Jack-0.52-preview-macOS.dmg"
        manifest["sparkleEdSignature"] = Data(repeating: 1, count: 64).base64EncodedString()
        manifest["sparkleLength"] = 512
        let preview = try UpdateRelease.decode(encoded())
        try preview.requireSparkleSignature()
        precondition(GitHubUpdates.assetURL(for:preview,in:repo).absoluteString == "https://github.com/example/apple-jack/releases/download/v0.52-preview.1/Apple-Jack-0.52-preview-macOS.dmg")
        for tag in ["../escape", "v0.53-preview.1", "v0.52-preview.0", "v0.52-preview.1?token=x"] {
            manifest["releaseTag"] = tag
            expectFailure { _ = try UpdateRelease.decode(encoded()) }
        }
        manifest["releaseTag"] = "v0.52-preview.1"
        for signature in ["invalid", Data(repeating: 1, count: 63).base64EncodedString(), ""] {
            manifest["sparkleEdSignature"] = signature
            expectFailure { try UpdateRelease.decode(encoded()).requireSparkleSignature() }
        }
        manifest["sparkleEdSignature"] = Data(repeating: 1, count: 64).base64EncodedString()
        for size in [0, 511, 1_073_741_825] {
            manifest["sparkleLength"] = size
            expectFailure { try UpdateRelease.decode(encoded()).requireSparkleSignature() }
        }
        manifest["sparkleLength"] = 512
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
        print("PASS HTTPS feed routing, version-pinned preview assets, signing metadata, missing release, private/beta rejection, installer filename, digest, and altered download checks.")
    }
}
