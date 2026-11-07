import Foundation

enum PetDiscoveryAccess {
    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let documents = home.appendingPathComponent("Documents", isDirectory: true).path
    static let cloudDocuments = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents", isDirectory: true).path

    // A configured pet root, package, app or sprite sheet may itself be a
    // symlink. Check each link target before opening the next path component.
    static func allowedURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        var components = ArraySlice(url.pathComponents.dropFirst())
        var path = "/"
        var links = 0
        while let component = components.popFirst() {
            if component == "." { continue }
            if component == ".." {
                path = (path as NSString).deletingLastPathComponent
                continue
            }
            path = (path as NSString).appendingPathComponent(component)
            var check = path.lowercased()
            let dataPrefix = "/system/volumes/data"
            if check.hasPrefix(dataPrefix + "/") { check.removeFirst(dataPrefix.count) }
            for dir in [documents, cloudDocuments] {
                if check == dir.lowercased() || check.hasPrefix(dir.lowercased() + "/") { return nil }
            }
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                links += 1
                guard links <= 32 else { return nil }
                path = target.hasPrefix("/") ? "/" : (path as NSString).deletingLastPathComponent
                let parts = (target as NSString).pathComponents.filter { $0 != "/" }
                components = ArraySlice(parts + components)
            }
        }
        return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
    }

    // The account connector starts a separate app server. Its own discovery
    // can consult saved workspaces even though the ephemeral thread is in /tmp.
    static func helperArguments(executable: URL) -> [String] {
        let profile = """
        (version 1)
        (allow default)
        (deny file-read* file-write* (subpath (param "DOCS")) (subpath (param "CLOUD_DOCS")))
        """
        return ["-D", "DOCS=" + documents, "-D", "CLOUD_DOCS=" + cloudDocuments,
                "-p", profile, executable.path, "app-server", "--listen", "stdio://"]
    }
}
