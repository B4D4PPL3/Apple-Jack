import AppKit

struct AppOpenRequest {
    let name: String
    var isBareName = false

    // Only direct requests enter the action path. Questions about opening apps,
    // quoted instructions, and model output are never executed as commands.
    static func parse(_ message: String) -> AppOpenRequest? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(?:(?:hey\s+)?(?:apple\s+jack|jack)[,:]?\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(?:open(?:\s+up)?|launch)\s+(.+?)[.!?]*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        var name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: #"(?i)(?:,?\s+please|\s+for\s+me)+$"#, with: "", options: .regularExpression)
        // "Open source alternatives…" is a topic, not an app command.
        if name.lowercased().hasPrefix("source ") { return nil }
        let specifiesApp = name.range(of: #"(?i)\s+(?:app|application)$"#, options: .regularExpression) != nil
        name = name.replacingOccurrences(of: #"(?i)\s+(?:app|application)$"#, with: "", options: .regularExpression)
        if specifiesApp { name = name.replacingOccurrences(of: #"(?i)^the\s+"#, with: "", options: .regularExpression) }
        name = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’")))
        guard !name.isEmpty else { return nil }
        return AppOpenRequest(name: name)
    }

    // A name is only a candidate until it matches the installed-app catalog.
    // Never extract an app name from a question or an instruction sentence.
    static func bareName(_ message: String) -> AppOpenRequest? {
        var name = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: [Character: Character] = ["\"": "\"", "'": "'", "“": "”", "‘": "’"]
        if name.count >= 2, let first = name.first, quotes[first] == name.last {
            name = String(name.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty, name.count <= 160,
              !name.contains(where: { $0.isNewline || $0 == "\0" }),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:@?!")) == nil else { return nil }
        let key = InstalledApp.normalized(name)
        let firstWord = key.split(separator: " ").first.map(String.init) ?? ""
        // Common conversational fragments can also be substrings of apps
        // (for example, "what" in WhatsApp). Leave them with the AI assistant.
        let conversational: Set<String> = ["hi", "hello", "hey", "thanks", "thank", "yes", "no", "ok", "okay",
            "what", "what's", "whats", "why", "how", "where", "when", "who", "which",
            "can", "could", "would", "will", "should", "do", "does", "did", "is", "are", "was", "were",
            "i", "i'm", "im", "my", "tell", "explain", "help", "please", "open", "launch"]
        guard !conversational.contains(firstWord) else { return nil }
        return AppOpenRequest(name: name, isBareName: true)
    }

    func matches(in apps: [InstalledApp]) -> [InstalledApp] {
        let meaningfulCount = InstalledApp.normalized(name).filter { $0.isLetter || $0.isNumber }.count
        // Very short fragments must be exact names/aliases, avoiding matches
        // such as "a" opening an arbitrary collection of installed apps.
        let partialName = meaningfulCount >= 3 && !name.lowercased().hasSuffix(".app")
        return AppCatalog.matches(name, in: apps, allowPartial: !isBareName || partialName)
    }
}

struct InstalledApp {
    let url: URL
    let name: String
    let searchNames: Set<String>

    init?(url: URL) {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: canonical),
              let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
              ["APPL", "FNDR"].contains(packageType),
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String != nil else { return nil }
        self.url = canonical
        let filename = canonical.deletingPathExtension().lastPathComponent
        let displayName = FileManager.default.displayName(atPath: canonical.path)
        name = displayName.lowercased().hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        let names = [filename, name, bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                     bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String].compactMap { $0 }
        searchNames = Set(names.map(Self.normalized))
    }

    static func normalized(_ name: String) -> String {
        var value = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if value.hasSuffix(".app") { value = String(value.dropLast(4)) }
        return value
    }
}

enum AppCatalog {
    static var defaultRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/System/Applications")]
    }

    static var systemApplicationURLs: [URL] {
        // Safari's /Applications entry can be a hidden link into Apple's
        // system-managed app volume. Keep hidden helpers out of the scan,
        // and ask Launch Services for this known system app explicitly.
        if let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
           InstalledApp(url: safari) != nil { return [safari] }
        // Also work while Launch Services is unavailable or refreshing.
        let paths = ["/Applications/Safari.app", "/System/Applications/Safari.app",
                     "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
        return paths.map { URL(fileURLWithPath: $0) }.filter { InstalledApp(url: $0) != nil }
    }

    // Skip app contents so embedded helper apps never become launch candidates.
    static func scan(roots: [URL] = defaultRoots, includeFinder: Bool = true,
                     systemApplications: [URL] = systemApplicationURLs) -> [InstalledApp] {
        // The same app can arrive as both a directory URL (with a trailing
        // slash) and a link URL. Use its resolved path to avoid duplicates.
        var apps: [String: InstalledApp] = [:]
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                if url.pathExtension.lowercased() == "app" {
                    files.skipDescendants()
                    if let app = InstalledApp(url: url) { apps[app.url.path] = app }
                } else if files.level >= 4 {
                    files.skipDescendants()
                }
            }
        }
        for url in systemApplications {
            if let app = InstalledApp(url: url) { apps[app.url.path] = app }
        }
        if includeFinder, let finder = InstalledApp(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")) {
            apps[finder.url.path] = finder
        }
        return apps.values.sorted {
            if $0.name == $1.name { return $0.url.path < $1.url.path }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func matches(_ name: String, in apps: [InstalledApp], allowPartial: Bool = true) -> [InstalledApp] {
        let key = InstalledApp.normalized(name)
        guard !key.isEmpty else { return [] }
        let exact = apps.filter { $0.searchNames.contains(key) }
        if !exact.isEmpty { return exact }
        let preferences = apps.contains { $0.searchNames.contains("system preferences") } ? "system preferences" : "system settings"
        let aliases = ["chrome": "google chrome", "settings": preferences, "system settings": preferences,
                       "system preferences": "system settings", "ical": "calendar",
                       "vs code": "visual studio code", "vscode": "visual studio code"]
        if let alias = aliases[key] {
            let known = apps.filter { $0.searchNames.contains(alias) }
            if !known.isEmpty { return known }
        }
        guard allowPartial else { return [] }
        // Keep every partial match so the existing chooser resolves ambiguity.
        // Match the entire fragment, never just a word extracted from a request.
        return apps.filter { app in app.searchNames.contains { $0.contains(key) } }
    }
}

enum NativeAppLauncher {
    static func open(_ app: InstalledApp, completion: @escaping (Result<Void, Error>) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { running, error in
            let outcome: Result<Void, Error>
            if let error = error { outcome = .failure(error) }
            else if let running = running, !running.isTerminated { outcome = .success(()) }
            else {
                outcome = .failure(NSError(domain: "AppleJack.AppLaunch", code: 1,
                                           userInfo: [NSLocalizedDescriptionKey: "macOS did not confirm that the app opened."]))
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
