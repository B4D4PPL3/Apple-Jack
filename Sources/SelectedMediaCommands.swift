import AppKit

// Native app commands are limited to Music and Spotify. Browser playback
// uses the checked system route or opens the player; no webpage scripts run.
final class SelectedMediaCommands {
    private let queue = DispatchQueue(label: "com.fonz.applejack.selected-media")
    private(set) var isBusy = false
    var busyDidChange: ((Bool) -> Void)?

    func send(_ command: MediaCommand, source: MediaSourceTarget, completion: @escaping (String?) -> Void) {
        guard !isBusy else { return }
        isBusy = true; busyDidChange?(true)
        queue.async { [weak self] in
            let error = Self.execute(command, source: source)
            DispatchQueue.main.async {
                self?.isBusy = false; self?.busyDidChange?(false)
                completion(error)
            }
        }
    }
    private static func execute(_ command: MediaCommand, source: MediaSourceTarget) -> String? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).contains(where: { $0.processIdentifier == source.processIdentifier && !$0.isTerminated }) else { return "That media app has closed. Choose another source." }
        let appID: String
        switch source.bundleIdentifier {
        case "com.apple.Music": appID = "com.apple.Music"
        case "com.spotify.client": appID = "com.spotify.client"
        default: return "Choose Automatic to control this player through macOS."
        }
        let action: String
        switch command { case .back: action = "previous track"; case .playPause: action = "playpause"; case .forward: action = "next track" }
        // Only fixed, app-owned constants enter the script source.
        let script = "with timeout of 12 seconds\ntell application id \"\(appID)\"\nif not running then return false\n\(action)\nreturn true\nend tell\nend timeout"
        var error: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
        return message(error) ?? (result?.booleanValue == true ? nil : "That player is unavailable.")
    }
    private static func message(_ error: NSDictionary?) -> String? {
        guard let error = error else { return nil }
        let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if code == -1743 || code == -1744 { return "Allow Apple Jack to control the selected app in System Settings → Privacy & Security → Automation." }
        if code == -1712 { return "The player took too long to respond. Check playback before trying again." }
        return "The selected app couldn’t complete that media command. Try its own playback controls."
    }
}
