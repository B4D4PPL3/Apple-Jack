import AppKit
import Carbon

// Static AppleScript plus typed Apple-event arguments. Media titles and URLs
// are data, never executable script. No JavaScript, page content or history.
enum SafariMediaScripts {
    static let inventory = """
    with timeout of 8 seconds
        tell application id "com.apple.Safari"
            if not running then return {}
            set rows to {}
            repeat with w in windows
                repeat with t in tabs of w
                    set tabPID to 0
                    try
                        set tabPID to pid of t
                    end try
                    set end of rows to {id of w, index of t, name of t, URL of t, tabPID}
                    if (count rows) ≥ 2000 then return rows
                end repeat
            end repeat
            return rows
        end tell
    end timeout
    """
    static let reveal = """
    on revealTab(windowID, tabIndex, expectedTitle, expectedURL)
        with timeout of 8 seconds
            tell application id "com.apple.Safari"
                if not running then return false
                set w to window id windowID
                set t to tab tabIndex of w
                -- Recheck immediately before switching: tabs can move or close
                -- while the user is answering a prompt or chooser.
                if (name of t as text) is not expectedTitle then return false
                if (URL of t as text) is not expectedURL then return false
                -- Activate first: doing this last can restore Safari's old key
                -- window after we have raised a previously minimized source.
                activate
                set current tab of w to t
                set miniaturized of w to false
                set index of w to 1
                return true
            end tell
        end timeout
    end revealTab
    """
}

final class NowPlayingSourceOpener {
    private let queue = DispatchQueue(label: "com.fonz.applejack.source-opening", qos: .userInitiated)
    private(set) var isBusy = false
    var busyDidChange: ((Bool) -> Void)?
    var currentTarget: (() -> MediaSourceTarget?)?

    func open(_ source: MediaSourceTarget) {
        guard !isBusy, !source.bundleIdentifier.isEmpty else { return }
        isBusy = true; busyDidChange?(true)
        guard source.bundleIdentifier == "com.apple.Safari" else {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).first,
                  let url = app.bundleURL else {
                finish("That player is no longer running. Start playback again and try the Now Playing card."); return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async { self?.finish(error == nil ? nil : "The player couldn’t be brought forward. Please open it from the Dock.") }
            }
            return
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty else {
            finish("Safari is no longer running. Start playback again and try the Now Playing card."); return
        }
        queue.async { [weak self] in
            var error: NSDictionary?
            let result = NSAppleScript(source: SafariMediaScripts.inventory)?.executeAndReturnError(&error)
            var tabs: [SafariMediaTab] = []
            if let result = result, result.numberOfItems > 0 {
                for i in 1...min(result.numberOfItems, 2000) {
                    guard let row = result.atIndex(i), row.numberOfItems == 5,
                          let title = row.atIndex(3)?.stringValue, let url = row.atIndex(4)?.stringValue else { continue }
                    tabs.append(SafariMediaTab(windowID: row.atIndex(1)!.int32Value, index: row.atIndex(2)!.int32Value,
                        title: title, url: url, processIdentifier: row.atIndex(5)!.int32Value))
                }
            }
            let failure = Self.message(for: error)
            DispatchQueue.main.async { self?.choose(tabs, source: source, error: failure) }
        }
    }

    private func choose(_ tabs: [SafariMediaTab], source: MediaSourceTarget, error: String?) {
        guard error == nil else { finish(error); return }
        guard currentTarget?() == source else { finish("The playing source changed. Click its updated card to try again."); return }
        let matches = SafariMediaMatcher.candidates(for: source, in: tabs)
        guard !matches.isEmpty else {
            finish("I couldn’t identify the playing Safari tab. Its page title may differ from the media title, or the tab may have closed. No new tab was opened."); return
        }
        var chosen = matches[0]
        if matches.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Choose the playing Safari tab"
            alert.informativeText = "Several open tabs match this media. Choose its window so Jack opens the right one."
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 28))
            for tab in matches {
                let item = NSMenuItem(title: "Window \(tab.windowID), tab \(tab.index) — \(tab.url)", action: nil, keyEquivalent: "")
                picker.menu?.addItem(item)
            }
            alert.accessoryView = picker
            alert.addButton(withTitle: "Open Source"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { finish(nil); return }
            chosen = matches[picker.indexOfSelectedItem]
        }
        guard currentTarget?() == source else { finish("The playing source changed. Click its updated card to try again."); return }
        let tab = chosen
        queue.async { [weak self] in
            var error: NSDictionary?
            let script = NSAppleScript(source: SafariMediaScripts.reveal)
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite),
                eventID: AEEventID(kASSubroutineEvent), targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(string: "revealTab"), forKeyword: AEKeyword(keyASSubroutineName))
            let arguments = NSAppleEventDescriptor.list()
            for (i, value) in [NSAppleEventDescriptor(int32: tab.windowID), NSAppleEventDescriptor(int32: tab.index),
                               NSAppleEventDescriptor(string: tab.title), NSAppleEventDescriptor(string: tab.url)].enumerated() {
                arguments.insert(value, at: i + 1)
            }
            event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))
            let result = script?.executeAppleEvent(event, error: &error)
            let failure = Self.message(for: error) ?? (result?.booleanValue == true ? nil : "That Safari tab moved, changed, or closed. Click the Now Playing card to try again.")
            DispatchQueue.main.async { self?.finish(failure) }
        }
    }
    private static func message(for error: NSDictionary?) -> String? {
        guard let error = error else { return nil }
        let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        if number == -1743 || number == -1744 {
            return "Allow Apple Jack to control Safari in System Settings → Privacy & Security → Automation. This lets Jack select the existing playing tab. Media playback buttons work without this permission."
        }
        if number == -1712 { return "Safari took too long to respond. Try clicking the card again after Safari finishes loading." }
        return "Safari couldn’t reveal that tab. It may have moved or closed. Try clicking the updated Now Playing card again."
    }
    private func finish(_ error: String?) {
        isBusy = false; busyDidChange?(false)
        guard let error = error else { return }
        let alert = NSAlert(); alert.messageText = "Couldn’t open playing source"
        alert.informativeText = error; alert.runModal()
    }
}
