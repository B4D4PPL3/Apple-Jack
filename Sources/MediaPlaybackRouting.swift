import Foundation

struct NativeMediaRequest: Codable, Equatable {
    let sourceKey: String
    let itemIdentifier: String
    let command: Int
}

// A visible source is not necessarily a controllable source. In particular,
// browser commands must not fall through to a different system media session.
enum MediaPlaybackRoute: Equatable {
    case automatic
    case application
    case native(NativeMediaRequest)
    case unavailable

    static func choose(_ command: MediaCommand, selection: String?,
                       snapshot: NowPlayingSnapshot?, automaticKey: String?) -> Self {
        guard let selection else { return .automatic }
        guard let snapshot, snapshot.sourceKey == selection else { return .unavailable }
        if ["com.apple.Music", "com.spotify.client"].contains(snapshot.bundleIdentifier),
           snapshot.processIdentifier > 0 { return .application }
        guard selection == automaticKey, !snapshot.nativeItemIdentifier.isEmpty else { return .unavailable }
        var identifier = command.rawValue
        if command == .playPause {
            let explicit = snapshot.playing ? 1 : 0
            if snapshot.nativeCommands.contains(explicit) { identifier = explicit }
        }
        guard snapshot.nativeCommands.contains(identifier) else { return .unavailable }
        return .native(NativeMediaRequest(sourceKey: selection,
            itemIdentifier: snapshot.nativeItemIdentifier, command: identifier))
    }
}
