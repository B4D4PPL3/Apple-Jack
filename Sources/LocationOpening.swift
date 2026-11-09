import AppKit

enum LocationOpenRequest: Equatable {
    case finder(URL)
    enum WebsiteTarget { case defaultBrowser, preview, safari }
    case website(URL, WebsiteTarget = .defaultBrowser)
    case invalid(String)

    static func parse(_ message: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> LocationOpenRequest? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Bare addresses and paths are intentional destinations; other text
        // remains a conversation unless it uses an explicit opening command.
        if let direct = directDestination(unquote(text), home: home) { return direct }
        let pattern = #"(?i)^(?:(?:hey\s+)?(?:apple\s+jack|jack)[,:]?\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(open(?:\s+up)?|launch|show|visit|go\s+to)\s+(.+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let verbRange = Range(match.range(at: 1), in: text),
              let targetRange = Range(match.range(at: 2), in: text) else {
            return folderAlias(text, home: home).map { .finder($0) }
        }
        let verb = String(text[verbRange]).lowercased()
        var target = String(text[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        var explicitSafari = false
        var hint: String? = verb == "visit" ? "website" : nil
        // Strip prose only for commands. Bare pasted paths remain literal,
        // and quotes protect filenames that themselves end in these words.
        for _ in 0..<2 {
            target = target.replacingOccurrences(of: #"(?i)(?:,?\s+please|\s+for\s+me)+[.!?]*$"#, with: "", options: .regularExpression)
            if let range = target.range(of: #"(?i)\s+in\s+(Safari|Finder)[.!?]*$"#, options: .regularExpression) {
                explicitSafari = target[range].lowercased().contains("safari")
                hint = explicitSafari ? "website" : "finder"
                target.removeSubrange(range)
            }
        }
        if let range = target.range(of: #"(?i)^(?:the\s+)?(?:folder|path)\s+"#, options: .regularExpression) {
            hint = "finder"; target.removeSubrange(range)
        } else if let range = target.range(of: #"(?i)^(?:the\s+)?(?:website|site)\s+"#, options: .regularExpression) {
            hint = "website"; target.removeSubrange(range)
        }
        target = unquote(target.trimmingCharacters(in: .whitespacesAndNewlines))
        if let location = directDestination(target, home: home) {
            if hint == "finder", case .website = location { return .invalid("Enter a Finder path, such as ~/Downloads, for this request.") }
            if hint == "website", case .finder = location { return .invalid("Enter a website address such as apple.com, or omit “in Safari” to open a path in Finder.") }
            if case .website(let url, _) = location {
                let preview = (verb == "open" || verb == "open up") && !explicitSafari
                return .website(url, preview ? .preview : .safari)
            }
            return location
        }
        if hint == "website" { return .invalid("Enter a website address such as apple.com or https://example.com.") }
        let folderName = target.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if let folder = folderAlias(folderName, home: home) { return .finder(folder) }
        if hint == "finder" { return .invalid("Enter a full Finder path, such as ~/Documents or /Users/yourname/Downloads.") }
        return nil
    }

    private static func directDestination(_ target: String, home: URL) -> LocationOpenRequest? {
        if target.contains(where: { $0.isNewline || $0 == "\0" }) { return nil }
        if target == "~" { return .finder(home) }
        if target.hasPrefix("~/") {
            return .finder(home.appendingPathComponent(String(target.dropFirst(2))).standardizedFileURL)
        }
        if target.hasPrefix("/") { return .finder(URL(fileURLWithPath: target).standardizedFileURL) }
        if target.lowercased().hasPrefix("file:") {
            guard let url = URL(string: target), url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  url.path.hasPrefix("/"), url.query == nil, url.fragment == nil else {
                return .invalid("That file address isn’t a local Finder path. Paste the path itself or a file:/// address.")
            }
            return .finder(URL(fileURLWithPath: url.path).standardizedFileURL)
        }
        return webAddress(target)
    }

    private static func webAddress(_ target: String) -> LocationOpenRequest? {
        let lower = target.lowercased()
        let hasWebScheme = lower.hasPrefix("https://") || lower.hasPrefix("http://")
        let invalid = LocationOpenRequest.invalid("That website address isn’t valid. Try a complete http:// or https:// address.")
        if !hasWebScheme, target.range(of: #"(?i)^(?:[a-z][a-z0-9+.-]*://|javascript:|data:|mailto:|tel:|https?:)"#, options: .regularExpression) != nil {
            return .invalid("Enter an http:// or https:// address, or a local Finder path.")
        }
        // Spaces in ordinary messages must not turn a conversation into a URL.
        guard !target.contains(where: { $0.isWhitespace || $0.isNewline }) else { return hasWebScheme ? invalid : nil }
        let source = hasWebScheme ? target : "https://" + target
        guard var components = URLComponents(string: source), let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else {
            return hasWebScheme ? invalid : nil
        }
        let plainHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = plainHost.split(separator: ".", omittingEmptySubsequences: false)
        let validLabels = labels.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        let local = plainHost.lowercased() == "localhost"
        let ipv4 = labels.count == 4 && labels.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        let domain = labels.count >= 2 && (labels.last?.contains(where: { $0.isLetter }) ?? false)
        guard validLabels, (hasWebScheme || domain || ipv4 || local),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            return hasWebScheme ? invalid : nil
        }
        // YouTube's apex host redirects to www with an application/binary
        // response. Safari can mistake that redirect for a download on its
        // first launch. Use the direct host, preserving paths/query/fragment.
        // Match the entire host so unrelated sites and subdomains stay literal.
        if host.lowercased() == "youtube.com", components.port == nil {
            components.host = "www.youtube.com"
            guard let directURL = components.url else { return invalid }
            return .website(directURL)
        }
        return .website(url)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let pairs: [Character: Character] = ["\"": "\"", "'": "'", "“": "”", "‘": "’"]
        if let first = value.first, pairs[first] == value.last { return String(value.dropFirst().dropLast()) }
        return value
    }

    private static func folderAlias(_ value: String, home: URL) -> URL? {
        var key = value.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if key == "my applications" || key == "my applications folder" { return home.appendingPathComponent("Applications", isDirectory: true) }
        key = key.replacingOccurrences(of: #"^(?:my|the)\s+"#, with: "", options: .regularExpression)
        key = key.replacingOccurrences(of: #"\s+folder$"#, with: "", options: .regularExpression)
        let folders = ["desktop": "Desktop", "documents": "Documents", "downloads": "Downloads", "pictures": "Pictures", "movies": "Movies"]
        if let folder = folders[key] { return home.appendingPathComponent(folder, isDirectory: true) }
        switch key {
        case "home", "home folder": return home
        case "applications": return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case "user applications": return home.appendingPathComponent("Applications", isDirectory: true)
        case "icloud", "icloud drive": return home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        default: return nil
        }
    }
}

enum NativeLocationOpener {
    static func openInDefaultBrowser(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        // Resolve the scheme itself so a site’s universal link cannot select a native app.
        guard let scheme = url.scheme, let schemeURL = URL(string: scheme + ":"),
              let browser = NSWorkspace.shared.urlForApplication(toOpen: schemeURL) else {
            completion(.failure(error("macOS couldn’t find a default browser for this address.")))
            return
        }
        open([url], with: browser, itemName: url.host ?? url.absoluteString, completion: completion)
    }

    static func openFinder(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .nameKey])
                let name = values.name ?? url.lastPathComponent
                DispatchQueue.main.async {
                    if values.isDirectory == true && values.isPackage != true {
                        guard let finder = existingApp(["/System/Library/CoreServices/Finder.app"]) else {
                            completion(.failure(error("I couldn’t find Finder on this Mac."))); return
                        }
                        open([url], with: finder, itemName: name, completion: completion)
                    } else if NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") {
                        completion(.success("Revealed \(name) in Finder."))
                    } else {
                        completion(.failure(error("Finder couldn’t reveal \(name).")))
                    }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func openWebsites(_ urls: [URL], completion: @escaping (Result<String, Error>) -> Void) {
        guard let first = urls.first else { return }
        let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            ?? existingApp(["/Applications/Safari.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"])
        guard let safari = safari else { completion(.failure(error("I couldn’t find Safari on this Mac."))); return }
        open(urls, with: safari, itemName: first.host ?? first.absoluteString, completion: completion)
    }

    private static func open(_ urls: [URL], with application: URL, itemName: String, completion: @escaping (Result<String, Error>) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { running, failure in
            let outcome: Result<String, Error>
            if let failure = failure { outcome = .failure(failure) }
            else if let running, !running.isTerminated {
                let appURL = running.bundleURL ?? application
                let name = running.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let appName = name.flatMap { $0.isEmpty ? nil : $0 } ?? appURL.deletingPathExtension().lastPathComponent
                outcome = .success("Opened \(itemName) in \(appName).")
            } else { outcome = .failure(error("macOS did not confirm that the destination opened.")) }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
    private static func existingApp(_ paths: [String]) -> URL? {
        paths.first(where: { FileManager.default.fileExists(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    private static func error(_ message: String) -> Error {
        NSError(domain: "AppleJack.LocationOpening", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
