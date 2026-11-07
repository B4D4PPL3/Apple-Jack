import AppKit
import AVFoundation

enum ReplyVoice {
    static let preferenceKey = "replyVoiceIdentifier"
    static let shortcutIdentifier = "applejack:shortcut"
    static let shortcutPreferenceKey = "speechShortcutName"
    static var usesShortcut: Bool { UserDefaults.standard.string(forKey: preferenceKey) == shortcutIdentifier }
    static var shortcutName: String {
        let saved = (UserDefaults.standard.string(forKey: shortcutPreferenceKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? "Jack Voice Test" : saved
    }
    static func automatic() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }
    static func selected() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: preferenceKey), !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return automatic()
    }
}

struct VoiceChoice {
    let identifier: String
    let shortcut: String
}

@MainActor
final class VoiceSettings: NSObject, AVSpeechSynthesizerDelegate {
    private let picker = NSPopUpButton(frame: NSRect(x: 0, y: 150, width: 440, height: 28))
    private let previewButton = NSButton(frame: NSRect(x: 0, y: 8, width: 140, height: 32))
    private let shortcutField = NSTextField(string: ReplyVoice.shortcutName)
    private let shortcutLabel = NSTextField(labelWithString: "Speech shortcut name")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let shortcutSpeech = ShortcutSpeech()
    private let synthesizer = AVSpeechSynthesizer()
    private var preview: AVSpeechUtterance?
    private var previewGeneration = 0
    private var voices: [AVSpeechSynthesisVoice] = []

    // nil means Cancel; an empty identifier selects the automatic voice.
    func run() -> VoiceChoice? {
        let preferredLanguage = (Locale.preferredLanguages.first ?? Locale.current.identifier).prefix(2)
        voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            let leftPreferred = $0.language.hasPrefix(preferredLanguage)
            let rightPreferred = $1.language.hasPrefix(preferredLanguage)
            if leftPreferred != rightPreferred { return leftPreferred }
            let order = Self.label($0).localizedStandardCompare(Self.label($1))
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        }
        picker.addItem(withTitle: "Automatic (\(ReplyVoice.automatic()?.name ?? "Mac default"))")
        // Use representedObject for identity: different voice variants can have
        // the same display name but must keep distinct saved identifiers.
        picker.lastItem?.representedObject = ""
        let shortcutItem = NSMenuItem(title: "Siri via Shortcuts", action: nil, keyEquivalent: "")
        shortcutItem.representedObject = ReplyVoice.shortcutIdentifier
        picker.menu?.addItem(shortcutItem)
        for voice in voices {
            let item = NSMenuItem(title: Self.label(voice), action: nil, keyEquivalent: "")
            item.representedObject = voice.identifier
            picker.menu?.addItem(item)
        }
        picker.setAccessibilityLabel("Reply voice")
        let saved = UserDefaults.standard.string(forKey: ReplyVoice.preferenceKey) ?? ""
        if let item = picker.itemArray.first(where: { ($0.representedObject as? String) == saved }) { picker.select(item) }
        let savedUnavailable = !saved.isEmpty && saved != ReplyVoice.shortcutIdentifier && !voices.contains { $0.identifier == saved }
        let alert = NSAlert()
        alert.messageText = "Reply Voice"
        alert.informativeText = "Choose a Mac voice or let a shortcut speak Jack’s replies with Siri’s voice. Preview it, then save.\(savedUnavailable ? " Your previously selected voice is unavailable; Jack is using Automatic." : "")"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 190))
        content.addSubview(picker)
        shortcutLabel.frame = NSRect(x: 0, y: 122, width: 440, height: 20)
        shortcutField.frame = NSRect(x: 0, y: 94, width: 440, height: 24)
        shortcutField.setAccessibilityLabel("Speech shortcut name")
        statusLabel.frame = NSRect(x: 0, y: 42, width: 440, height: 46)
        statusLabel.font = .systemFont(ofSize: 11)
        content.addSubview(shortcutLabel); content.addSubview(shortcutField); content.addSubview(statusLabel)
        previewButton.title = "Preview"
        previewButton.bezelStyle = .rounded
        previewButton.target = self; previewButton.action = #selector(togglePreview)
        content.addSubview(previewButton)
        picker.target = self; picker.action = #selector(selectionChanged)
        alert.accessoryView = content
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = picker
        synthesizer.delegate = self
        selectionChanged()
        defer { stopPreview() }
        while alert.runModal() == .alertFirstButtonReturn {
            let id = picker.selectedItem?.representedObject as? String ?? ""
            let name = shortcutField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if id == ReplyVoice.shortcutIdentifier && name.isEmpty {
                alert.informativeText = "Enter the name of the shortcut that will speak Jack’s responses, such as Jack Voice Test."
                continue
            }
            return VoiceChoice(identifier: id, shortcut: name.isEmpty ? ReplyVoice.shortcutName : name)
        }
        return nil
    }
    private static func label(_ voice: AVSpeechSynthesisVoice) -> String {
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        let quality: String
        switch voice.quality {
        case .enhanced: quality = " · Enhanced"
        case .premium: quality = " · Premium"
        default: quality = ""
        }
        return "\(voice.name) — \(language)\(quality)"
    }
    @objc private func selectionChanged() {
        stopPreview()
        let viaShortcut = (picker.selectedItem?.representedObject as? String) == ReplyVoice.shortcutIdentifier
        shortcutLabel.isHidden = !viaShortcut; shortcutField.isHidden = !viaShortcut
        statusLabel.stringValue = viaShortcut ? "The shortcut must speak its Shortcut Input using Siri Voice 2, with Wait Until Finished enabled. See Setup Guide for the two actions." : "Preview your selected voice before saving."
    }
    @objc private func togglePreview() {
        if preview != nil || shortcutSpeech.isActive { stopPreview(); return }
        previewGeneration += 1
        let id = picker.selectedItem?.representedObject as? String ?? ""
        if id == ReplyVoice.shortcutIdentifier {
            let generation = previewGeneration
            previewButton.title = "Stop Preview"
            statusLabel.stringValue = "Running your speech shortcut…"
            shortcutSpeech.play("Hi, I’m Apple Jack. This is how I’ll sound when I reply.", shortcut: shortcutField.stringValue) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self, self.previewGeneration == generation else { return }
                    self.previewButton.title = "Preview"
                    self.statusLabel.stringValue = error ?? "Preview finished. Save to use this shortcut for spoken replies."
                    self.statusLabel.toolTip = error
                }
            }
            return
        }
        let utterance = AVSpeechUtterance(string: "Hi, I’m Apple Jack. This is how I’ll sound when I reply.")
        utterance.voice = id.isEmpty ? ReplyVoice.automatic() : AVSpeechSynthesisVoice(identifier: id)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        preview = utterance
        previewButton.title = "Stop Preview"
        synthesizer.speak(utterance)
    }
    private func stopPreview() {
        previewGeneration += 1
        shortcutSpeech.cancel()
        preview = nil
        synthesizer.stopSpeaking(at: .immediate)
        previewButton.title = "Preview"
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished(utterance) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished(utterance) }
    private nonisolated func finished(_ utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let active = self.preview, ObjectIdentifier(active) == identity else { return }
            self.preview = nil
            self.previewButton.title = "Preview"
        }
    }
}
