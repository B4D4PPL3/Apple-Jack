import AppKit

final class KeyboardShortcutSettings: NSObject {
    private struct Row {
        let title: String
        let controller: KeyboardShortcutController
        let enabled: NSButton
        let combination: NSTextField
        let record: NSButton
        var candidate: JackShortcut
    }
    private let alert = NSAlert()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private var rows: [Row] = []
    private var recording: Int?
    private var monitor: Any?

    func run(show: KeyboardShortcutController, center: KeyboardShortcutController, hide: KeyboardShortcutController) {
        let definitions = [
            ("Show Apple Jack", "Open the bubble in place; press again while active to close it.", show),
            ("Center & Show Apple Jack", "Center Jack on the display with your pointer and open the bubble.", center),
            ("Hide Apple Jack", "Hide Jack and his speech bubble from every display.", hide)
        ]
        let startupErrors = definitions.compactMap { title, _, controller in controller.errorMessage.map { title + ": " + $0 } }
        definitions.forEach { $0.2.pauseForSettings() }
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = "Choose a combination for each action, or turn an action’s shortcut off. Changes apply together when you save."
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 354))
        for (index, definition) in definitions.enumerated() {
            let (title, detail, controller) = definition
            let row = NSView(frame: NSRect(x: 0, y: 48 + (2 - index) * 102, width: 480, height: 96))
            let enabled = NSButton(checkboxWithTitle: title, target: self, action: #selector(enabledChanged(_:)))
            enabled.tag = index; enabled.state = controller.enabled ? .on : .off
            enabled.frame = NSRect(x: 0, y: 72, width: 476, height: 24)
            let subtitle = NSTextField(labelWithString: detail)
            subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor
            subtitle.frame = NSRect(x: 0, y: 50, width: 480, height: 18)
            let combination = NSTextField(labelWithString: "")
            combination.frame = NSRect(x: 0, y: 15, width: 185, height: 27)
            combination.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
            combination.lineBreakMode = .byTruncatingTail
            combination.setAccessibilityLabel(title + " shortcut combination")
            let record = NSButton(title: "Record Shortcut", target: self, action: #selector(beginRecording(_:)))
            record.tag = index; record.bezelStyle = .rounded
            record.frame = NSRect(x: 190, y: 12, width: 150, height: 30)
            record.setAccessibilityLabel("Record " + title + " shortcut")
            let reset = NSButton(title: "Use Default", target: self, action: #selector(resetShortcut(_:)))
            reset.tag = index; reset.bezelStyle = .rounded
            reset.frame = NSRect(x: 345, y: 12, width: 130, height: 30)
            reset.toolTip = "Restore default: " + controller.defaultBinding.display
            reset.setAccessibilityLabel("Restore default " + title + " shortcut")
            for view in [enabled, subtitle, combination, record, reset] { row.addSubview(view) }
            if index < 2 {
                let line = NSBox(frame: NSRect(x: 0, y: 0, width: 480, height: 1)); line.boxType = .separator
                row.addSubview(line)
            }
            content.addSubview(row)
            rows.append(Row(title: title, controller: controller, enabled: enabled,
                            combination: combination, record: record, candidate: controller.binding))
        }
        explanation.frame = NSRect(x: 0, y: 0, width: 480, height: 42)
        explanation.font = .systemFont(ofSize: 11)
        content.addSubview(explanation)
        alert.accessoryView = content
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        refresh()
        if let message = startupErrors.first { showError(message) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let index = self.recording, event.window === self.rows[index].record.window else { return event }
            if event.keyCode == 53 { self.recording = nil; self.refresh(); return nil }
            guard !event.isARepeat else { return nil }
            let value = JackShortcut(event: event)
            guard value.isValid else {
                self.showError("Hold Control, Option, or Command, then press a key. Escape cancels recording.")
                return nil
            }
            self.rows[index].candidate = value; self.recording = nil; self.refresh()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.editInJack(validate: { [self] in
            recording = nil
            let changes = rows.map { (controller: $0.controller, binding: $0.candidate, enabled: $0.enabled.state == .on) }
            if let failure = KeyboardShortcutController.applyTogether(changes) {
                refresh(); showError(rows[failure.index].title + ": " + failure.message)
                return false
            }
            return true
        }) { [self] _ in
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            rows.forEach { $0.controller.resumeAfterSettings() }
        }
    }
    @objc private func beginRecording(_ sender: NSButton) { recording = sender.tag; refresh() }
    @objc private func resetShortcut(_ sender: NSButton) {
        rows[sender.tag].candidate = rows[sender.tag].controller.defaultBinding
        recording = nil; refresh()
    }
    @objc private func enabledChanged(_ sender: NSButton) { recording = nil; refresh() }
    private func showError(_ message: String) { explanation.stringValue = message; explanation.textColor = .systemRed }
    private func refresh() {
        for (index, row) in rows.enumerated() {
            row.combination.stringValue = row.candidate.display
            row.combination.toolTip = row.candidate.display
            row.record.isEnabled = row.enabled.state == .on
            row.record.title = recording == index ? "Press keys…" : "Record Shortcut"
        }
        explanation.textColor = .secondaryLabelColor
        explanation.stringValue = recording.map { "Recording \(rows[$0].title). Press your combination; Escape cancels recording." }
            ?? "Saved on this Mac. Jack must be running. If macOS already uses a combination, choose another here."
    }
}
