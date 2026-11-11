import AppKit

struct SetupShortcut {
    let title: String
    let fileName: String
    let configuredName: String
    let detail: String

    func installedName(in names: Set<String>) -> String? {
        [configuredName, fileName].first(where: names.contains)
    }
}

final class ShortcutSetup: NSObject, NSWindowDelegate {
    private let shortcuts: () -> [SetupShortcut]
    private var panel: NSWindow?
    private var buttons: [NSButton] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private var checking = false
    private let tryButton = NSButton(title: "Try ChatGPT", target: nil, action: nil)
    private let replyStatus = NSTextField(wrappingLabelWithString: "")
    private var replyChecks: [String: Bool] = [:]
    var tryChatGPT: (() -> Bool)?
    var continueWithoutAI: (() -> Void)?

    // Evidence of a returned text response, not a claim about system configuration.
    // Kept only for this session and keyed by the exact answering shortcut.
    func recordReply(shortcut: String, receivedText: Bool) {
        replyChecks[shortcut] = receivedText
        updateReplyStatus()
    }
    private func updateReplyStatus() {
        switch replyChecks[AIBackend.chatGPTShortcut] {
        case true?: replyStatus.stringValue = "ChatGPT shortcut: text reply received this session."
        case false?: replyStatus.stringValue = "ChatGPT shortcut: the last attempt did not return a reply. Check the extension and shortcut settings, then try again."
        case nil: replyStatus.stringValue = "ChatGPT shortcut: no reply tested this session."
        }
    }

    init(shortcuts: @escaping () -> [SetupShortcut]) {
        self.shortcuts = shortcuts
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(returnedToJack),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }
    @objc private func returnedToJack() { if refreshButton.window?.isVisible == true { refresh() } }

    func show() {
        if panel == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        if let nav = BubbleNavigation.current, let panel { nav.show(panel, title: "Set Up Shortcuts") }
        else { panel?.makeKeyAndOrderFront(nil) }
        refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 590),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        func add(_ view: NSView) {
            rows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        func text(_ value: String, heading: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = heading ? .boldSystemFont(ofSize: 14) : .systemFont(ofSize: 12)
            label.textColor = heading ? .labelColor : .secondaryLabelColor
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            add(label)
        }
        text("1. Install the shortcuts", heading: true)
        text("Installed means a shortcut is in your library. It does not confirm that Apple Intelligence, ChatGPT, or Siri is set up.")
        for (index, item) in shortcuts().enumerated() {
            let title = NSTextField(labelWithString: item.title)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let detail = NSTextField(wrappingLabelWithString: item.detail)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            let labels = NSStackView(views: [title, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3
            let button = NSButton(title: "Checking…", target: self, action: #selector(addShortcut(_:)))
            button.isEnabled = false
            button.tag = index
            button.widthAnchor.constraint(equalToConstant: 112).isActive = true
            buttons.append(button)
            let row = NSStackView(views: [labels, NSView(), button])
            add(row)
        }
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        add(NSStackView(views: [status, NSView(), refreshButton]))
        let separator = NSBox(); separator.boxType = .separator; add(separator)
        text("2. Enable ChatGPT on your Mac", heading: true)
        text("In System Settings, open Siri (Apple Intelligence & Siri on some macOS versions), then ChatGPT or Set Up Extensions → ChatGPT. Complete setup and enable the extension. Signing in to the ChatGPT app alone does not enable this extension.")
        let help = NSButton(title: "Apple’s Setup Instructions", target: self, action: #selector(openSetupHelp))
        add(NSStackView(views: [help, NSView()]))
        text("3. Ask your first question", heading: true)
        text("Try ChatGPT selects it in AI Assistant and returns to Jack’s message field. If the field is empty, Jack adds a sample question. Press Enter to send it through your ChatGPT shortcut; a returned answer confirms the reply path worked.")
        tryButton.target = self
        tryButton.action = #selector(beginChatGPT)
        tryButton.toolTip = "Select ChatGPT and prepare a question. Nothing is sent until you press Enter."
        add(NSStackView(views: [tryButton, NSView()]))
        replyStatus.font = .systemFont(ofSize: 12)
        replyStatus.textColor = .secondaryLabelColor
        add(replyStatus)
        updateReplyStatus()
        let secondSeparator = NSBox(); secondSeparator.boxType = .separator; add(secondSeparator)
        text("You can use Jack without AI", heading: true)
        text("Pets, Hold This, clipboard history, Favorites, media controls, and opening apps, folders, and websites work without AI setup. AI chat and Summarize, Rewrite, and Explain need a working assistant. Siri speech is optional and uses its own shortcut. Some Mac tools may ask for their usual permissions.")
        let skip = NSButton(title: "Continue without AI Setup", target: self, action: #selector(skipSetup))
        add(NSStackView(views: [skip, NSView()]))

        // Keep the steps readable on small displays without making the page draggable.
        let scroll = NSScrollView()
        scroll.identifier = NSUserInterfaceItemIdentifier("AppleJackShortcutSetup")
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let document = ShortcutSetupDocument()
        document.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: document.topAnchor, constant: 16),
            rows.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        panel = window
        window.center()
    }

    @objc private func openSetupHelp() {
        NSWorkspace.shared.open(URL(string: "https://support.apple.com/guide/mac-help/mchlfc5cf131/mac")!)
    }
    @objc private func beginChatGPT() {
        if tryChatGPT?() != true {
            replyStatus.stringValue = "Finish the current request or dictation, then choose Try ChatGPT again."
        }
    }
    @objc private func skipSetup() { continueWithoutAI?() }

    @objc private func refresh() {
        guard !checking else { return }
        checking = true
        tryButton.isEnabled = false
        refreshButton.isEnabled = false
        buttons.forEach { $0.isEnabled = false; $0.title = "Checking…" }
        status.stringValue = "Checking your Shortcuts library…"
        DispatchQueue.global(qos: .userInitiated).async {
            let names = Self.installedNames()
            DispatchQueue.main.async { self.display(names) }
        }
    }

    private static func installedNames() -> Set<String>? {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        task.arguments = ["list"]
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardOutput = output
        do { try task.run() } catch { return nil }
        let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timeout.cancel()
        guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        return Set(text.components(separatedBy: .newlines))
    }

    private func display(_ names: Set<String>?) {
        checking = false
        refreshButton.isEnabled = true
        let items = shortcuts()
        tryButton.isEnabled = names?.contains(AIBackend.chatGPTShortcut) == true
        updateReplyStatus()
        if let names, !names.contains(AIBackend.chatGPTShortcut) {
            replyStatus.stringValue = "Add the ChatGPT shortcut above. If you use a custom name, check AI Assistant → ChatGPT Shortcut Settings. The selected shortcut must be installed before trying it."
        }
        if let names {
            if items.contains(where: { $0.installedName(in: names) == nil }) {
                status.stringValue = "Choose Add, then confirm in Shortcuts."
            } else {
                status.stringValue = "All three shortcuts are installed. AI setup is separate."
            }
        } else {
            status.stringValue = "Couldn’t read your library. Open Shortcuts, then click Refresh."
        }
        for (item, button) in zip(items, buttons) {
            let installed = names.flatMap { item.installedName(in: $0) }
            button.title = names == nil ? "Unavailable" : installed == nil ? "Add…" : "Installed"
            button.isEnabled = names != nil && installed == nil
            button.toolTip = installed ?? item.fileName
            button.setAccessibilityLabel("\(item.title): \(button.title)")
        }
    }

    @objc private func addShortcut(_ sender: NSButton) {
        let item = shortcuts()[sender.tag]
        guard let file = Bundle.main.url(forResource: item.fileName, withExtension: "shortcut", subdirectory: "Shortcuts"),
              let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else {
            status.stringValue = "Couldn’t find the shortcut file or the Shortcuts app."
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription } }
        }
    }
}
private final class ShortcutSetupDocument: NSView {
    override var isFlipped: Bool { true }
}
