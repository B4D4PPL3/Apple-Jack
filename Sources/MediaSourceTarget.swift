import Foundation

struct MediaSourceTarget: Equatable {
    let title: String
    let artist: String
    let bundleIdentifier: String
    let processIdentifier: Int32
    let url: URL?
    init(_ snapshot: NowPlayingSnapshot) {
        title = snapshot.title; artist = snapshot.artist
        bundleIdentifier = snapshot.bundleIdentifier
        processIdentifier = snapshot.processIdentifier; url = snapshot.sourceURL
    }
}

struct SafariMediaTab: Equatable {
    let windowID: Int32
    let index: Int32
    let title: String
    let url: String
    let processIdentifier: Int32
}

enum SafariMediaMatcher {
    static func normalized(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\u{200b}", with: "")
            .replacingOccurrences(of: "\u{feff}", with: "")
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
    static func pageTitle(_ text: String) -> String {
        var title = normalized(text)
        // Safari/YouTube may prefix an unread notification count.
        title = title.replacingOccurrences(of: #"^\([0-9]+\)\s+"#, with: "", options: .regularExpression)
        for suffix in [" - youtube", " | youtube", " - vimeo", " - twitch"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        return title
    }
    static func candidates(for source: MediaSourceTarget, in tabs: [SafariMediaTab]) -> [SafariMediaTab] {
        // A URL identifies the existing page; never navigate or create a tab.
        if let url = source.url {
            let exact = tabs.filter { URL(string: $0.url) == url }
            if !exact.isEmpty { return narrow(exact, pid: source.processIdentifier) }
        }
        let title = pageTitle(source.title)
        guard !title.isEmpty else { return [] }
        let matches = tabs.filter { pageTitle($0.title) == title }
        if !matches.isEmpty { return narrow(matches, pid: source.processIdentifier) }
        // Some native WebKit clients report a WebContent PID. GPU/shared
        // processes won't match. Only a unique process-backed tab is usable.
        let processMatches = tabs.filter { source.processIdentifier > 0 && $0.processIdentifier == source.processIdentifier }
        return processMatches.count == 1 ? processMatches : []
    }
    private static func narrow(_ tabs: [SafariMediaTab], pid: Int32) -> [SafariMediaTab] {
        let matchingProcess = tabs.filter { pid > 0 && $0.processIdentifier == pid }
        return matchingProcess.isEmpty ? tabs : matchingProcess
    }
}
