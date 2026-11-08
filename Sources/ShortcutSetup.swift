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

    init(shortcuts: @escaping () -> [SetupShortcut]) { self.shortcuts = shortcuts }

    func show() {
        if panel == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        refresh()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 273),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Shortcuts"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 16
        for (index, item) in shortcuts().enumerated() {
            let title = NSTextField(labelWithString: item.title)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let detail = NSTextField(labelWithString: item.detail)
            detail.textColor = .secondaryLabelColor
            let labels = NSStackView(views: [title, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 3
            let button = NSButton(title: "Checking…", target: self, action: #selector(addShortcut(_:)))
            button.isEnabled = false
            button.tag = index
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
            buttons.append(button)
            let row = NSStackView(views: [labels, NSView(), button])
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let footer = NSStackView(views: [status, NSView(), refreshButton])
        rows.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        let content = window.contentView!
        content.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -14)
        ])
        panel = window
        window.center()
    }

    @objc private func refresh() {
        guard !checking else { return }
        checking = true
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
        if let names {
            if items.contains(where: { $0.installedName(in: names) == nil }) {
                status.stringValue = "Choose Add, then confirm in Shortcuts."
            } else {
                status.stringValue = "All three shortcuts are in your library."
            }
        } else {
            status.stringValue = "Couldn’t read your library. Open Shortcuts, then click Refresh."
        }
        for (item, button) in zip(items, buttons) {
            let installed = names.flatMap { item.installedName(in: $0) }
            button.title = names == nil ? "Unavailable" : installed == nil ? "Add…" : "Already Added"
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
