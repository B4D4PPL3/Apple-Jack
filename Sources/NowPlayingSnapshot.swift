import Foundation

struct NowPlayingSnapshot {
    let sourceKey: String
    let title: String
    let artist: String
    let bundleIdentifier: String
    let playing: Bool
    let artwork: Data?
    let processIdentifier: Int32
    let sourceURL: URL?
    let nativeItemIdentifier: String
    let nativeCommands: Set<Int>

    init?(payload: [String: Any]) {
        guard let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let playing = payload["playing"] as? Bool else { return nil }
        sourceKey = String((payload["sourceKey"] as? String ?? "").prefix(2048))
        self.title = String(title.prefix(2048))
        artist = String((payload["artist"] as? String ?? "").prefix(1024))
        bundleIdentifier = String((payload["parentApplicationBundleIdentifier"] as? String
            ?? payload["bundleIdentifier"] as? String ?? "").prefix(512))
        self.playing = playing
        processIdentifier = (payload["processIdentifier"] as? NSNumber)?.int32Value ?? 0
        let item = payload["nativeItemIdentifier"] as? String ?? ""
        nativeItemIdentifier = item.utf8.count <= 8192 && !item.contains("\0") ? item : ""
        nativeCommands = Set((payload["nativeCommands"] as? [Int] ?? []).filter { [0, 1, 2, 4, 5].contains($0) })
        sourceURL = [payload["sourceURL"], payload["contentItemIdentifier"]].compactMap { value -> URL? in
            guard let text = value as? String, text.count <= 8192,
                  let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil else { return nil }
            return url
        }.first
        if let encoded = payload["artworkData"] as? String, encoded.utf8.count <= 6 * 1024 * 1024 {
            artwork = Data(base64Encoded: encoded)
        } else { artwork = nil }
    }
}

// A pipe read is not necessarily one JSON message. Keep framing independent of
// Process/AppKit so partial frames and stale/empty state can be tested directly.
final class NowPlayingDecoder {
    enum Failure: Error { case oversizedFrame, malformedMessage }
    private var pending = Data()
    private let maximumFrame = 8 * 1024 * 1024

    func append(_ bytes: Data) throws -> [NowPlayingSnapshot?] {
        try appendCatalog(bytes).map { $0.automatic }
    }

    func appendCatalog(_ bytes: Data) throws -> [MediaCatalogSnapshot] {
        pending.append(bytes)
        var updates: [MediaCatalogSnapshot] = []
        while let end = pending.firstIndex(of: 10) {
            guard end <= maximumFrame else { pending.removeAll(); throw Failure.oversizedFrame }
            let line = pending.prefix(upTo: end)
            pending.removeSubrange(...end)
            if line.isEmpty { continue }
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  message["type"] as? String == "data",
                  message["diff"] as? Bool == false,
                  let payload = message["payload"] as? [String: Any] else { throw Failure.malformedMessage }
            let sources = (message["sources"] as? [[String: Any]] ?? []).prefix(32).compactMap(NowPlayingSnapshot.init)
            updates.append(MediaCatalogSnapshot(automatic: NowPlayingSnapshot(payload: payload), sources: sources))
        }
        guard pending.count <= maximumFrame else { pending.removeAll(); throw Failure.oversizedFrame }
        return updates
    }
}

// Manual selection is session-local. Losing a source never silently targets another app.
struct MediaCatalogSnapshot {
    var automatic: NowPlayingSnapshot?
    var sources: [NowPlayingSnapshot]
    func selected(_ key: String?) -> NowPlayingSnapshot? {
        guard let key = key else { return automatic }
        return sources.first { $0.sourceKey == key }
    }
}
