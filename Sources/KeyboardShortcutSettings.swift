import AppKit

final class KeyboardShortcutSettings: NSObject {
    private let alert = NSAlert()
    private let enabled = NSButton(checkboxWithTitle: "Enable keyboard shortcut", target: nil, action: nil)
    private let combination = NSTextField(labelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let record = NSButton(title: "Record Shortcut", target: nil, action: nil)
    private var candidate = JackShortcut.defaultShortcut
    private var defaultBinding = JackShortcut.defaultShortcut
    private var recording = false
    private var monitor: Any?

    func run(controller: KeyboardShortcutController, other: KeyboardShortcutController, hide: Bool = false) {
        defaultBinding = controller.defaultBinding
        candidate = controller.binding
        enabled.state = controller.enabled ? .on : .off
        let startupError = controller.errorMessage
        controller.pauseForSettings()
        other.pauseForSettings()
        alert.messageText = hide ? "Hide Apple Jack Shortcut" : "Keyboard Shortcut"
        alert.informativeText = hide ? "Hide Jack and his speech bubble from anywhere on your Mac." : "Bring Jack and his speech bubble forward, ready to type. Press again while the bubble is active to close it. Jack briefly glows green to help you find him."
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 166))
        enabled.frame = NSRect(x: 0, y: 140, width: 390, height: 24)
        enabled.target = self; enabled.action = #selector(enabledChanged)
        combination.frame = NSRect(x: 0, y: 94, width: 200, height: 30)
        combination.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        combination.setAccessibilityLabel("Keyboard shortcut combination")
        record.frame = NSRect(x: 215, y: 92, width: 200, height: 32)
        record.bezelStyle = .rounded; record.target = self; record.action = #selector(beginRecording)
        let reset = NSButton(title: "Restore Default: \(defaultBinding.display)", target: self, action: #selector(resetShortcut))
        reset.bezelStyle = .rounded; reset.frame = NSRect(x: 0, y: 48, width: 210, height: 30)
        explanation.frame = NSRect(x: 0, y: 0, width: 420, height: 42)
        explanation.font = .systemFont(ofSize: 11); explanation.textColor = .secondaryLabelColor
        for view in [enabled, combination, record, reset, explanation] { content.addSubview(view) }
        alert.accessoryView = content
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        refresh()
        if let startupError { explanation.stringValue = startupError }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.window === self.record.window else { return event }
            if event.keyCode == 53 { self.recording = false; self.refresh(); return nil }
            guard !event.isARepeat else { return nil }
            let value = JackShortcut(event: event)
            guard value.isValid else {
                self.explanation.stringValue = "Hold Control, Option, or Command, then press a key. Escape cancels recording."
                return nil
            }
            self.candidate = value; self.recording = false; self.refresh()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.editInJack(validate: { [self] in
            recording = false
            if enabled.state == .on && other.enabled && candidate == other.binding {
                explanation.stringValue = "Jack already uses that combination for his other keyboard shortcut."
                return false
            }
            if controller.apply(candidate, enabled: enabled.state == .on) { return true }
            refresh()
            explanation.stringValue = controller.errorMessage ?? "Couldn’t save that shortcut. Your previous setting is unchanged."
            return false
        }) { [self] _ in
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            controller.resumeAfterSettings()
            other.resumeAfterSettings()
        }
    }
    @objc private func beginRecording() { recording = true; refresh() }
    @objc private func resetShortcut() { candidate = defaultBinding; recording = false; refresh() }
    @objc private func enabledChanged() { recording = false; refresh() }
    private func refresh() {
        combination.stringValue = candidate.display
        record.isEnabled = enabled.state == .on
        record.title = recording ? "Press keys…" : "Record Shortcut"
        explanation.stringValue = recording ? "Press your combination now. Escape cancels recording."
            : "Default: \(defaultBinding.display). Saved on this Mac. Jack must be running."
    }
}
