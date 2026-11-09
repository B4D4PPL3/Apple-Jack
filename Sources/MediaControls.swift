import AppKit

final class MediaControls: NSObject, NSMenuDelegate {
    let view = NSStackView()
    let outputPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var observer: AudioOutputObserver?
    private var menuIsOpen = false
    private let runner = MediaCommandRunner()
    private let selectedCommands = SelectedMediaCommands()
    private var snapshot: NowPlayingSnapshot?
    private var transportButtons: [PlaybackTransportButton] = []
    private let openPlayerButton = NSButton(title: "Open Player", target: nil, action: nil)
    private var sourceKey: String?
    private var automaticKey: String?
    var openPlayer: (() -> Void)?
    func selectSource(_ key: String?, snapshot: NowPlayingSnapshot?, automaticKey: String?) {
        sourceKey = key; self.snapshot = snapshot; self.automaticKey = automaticKey
        for button in transportButtons { button.glyphColor = snapshot?.waveformColor ?? PlaybackBars.emptyColor }
        openPlayerButton.contentTintColor = snapshot?.waveformColor
        updateTransport()
    }
    private func route(_ command: MediaCommand) -> MediaPlaybackRoute {
        .choose(command, selection: sourceKey, snapshot: snapshot, automaticKey: automaticKey)
    }
    private func updateTransport() {
        let needsPlayer = sourceKey != nil && snapshot != nil && MediaCommand.allCases.allSatisfy { route($0) == .unavailable }
        for button in transportButtons {
            button.isHidden = needsPlayer
            button.isEnabled = !isBusy && route(MediaCommand(rawValue: button.tag)!) != .unavailable
        }
        openPlayerButton.isHidden = !needsPlayer
        openPlayerButton.isEnabled = !isBusy
    }
    @objc private func showPlayer() { openPlayer?() }
    var isBusy: Bool { runner.isBusy || selectedCommands.isBusy }
    func cancel() { runner.cancel() }

    override init() {
        super.init()
        view.spacing = 4
        view.detachesHiddenViews = true
        view.alignment = .centerY
        for (key, symbol, label, hint) in [
            (MediaCommand.back, "backward.end.fill", "Back", "Previous track in your selected media player"),
            (.playPause, "playpause.fill", "Play or pause", "Play or pause your selected media player"),
            (.forward, "forward.end.fill", "Forward", "Next track in your selected media player")
        ] {
            let button = PlaybackTransportButton(glyph: JackIcon.image(named: symbol, accessibilityDescription: label)!)
            button.target = self
            button.action = #selector(transport(_:))
            button.tag = key.rawValue
            button.setAccessibilityLabel(label)
            button.toolTip = hint
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            view.addArrangedSubview(button)
            transportButtons.append(button)
        }
        openPlayerButton.bezelStyle = .texturedRounded
        openPlayerButton.font = .systemFont(ofSize: 11)
        openPlayerButton.target = self
        openPlayerButton.action = #selector(showPlayer)
        openPlayerButton.toolTip = "This source needs its own playback controls. Open the playing app or Safari tab."
        openPlayerButton.setAccessibilityHelp(openPlayerButton.toolTip)
        openPlayerButton.widthAnchor.constraint(equalToConstant: 92).isActive = true
        openPlayerButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        openPlayerButton.isHidden = true
        view.addArrangedSubview(openPlayerButton)
        runner.busyDidChange = { [weak self] _ in self?.updateTransport() }
        selectedCommands.busyDidChange = { [weak self] _ in self?.updateTransport() }
        outputPicker.controlSize = .small
        outputPicker.font = .systemFont(ofSize: 11)
        outputPicker.cell?.lineBreakMode = .byTruncatingTail
        outputPicker.setAccessibilityLabel("Audio output device")
        outputPicker.target = self
        outputPicker.action = #selector(selectOutput)
        outputPicker.menu?.delegate = self
        outputPicker.widthAnchor.constraint(equalToConstant: 132).isActive = true
        view.addArrangedSubview(outputPicker)
        refreshOutputs()
        observer = AudioOutputObserver { [weak self] in
            guard let self = self, !self.menuIsOpen else { return }
            self.refreshOutputs()
        }
    }

    @objc private func transport(_ sender: NSButton) {
        guard let command = MediaCommand(rawValue: sender.tag) else { return }
        let selected = sourceKey
        let target = snapshot.map(MediaSourceTarget.init)
        let completion: (String?) -> Void = { [weak self] error in
            guard let self, let error else { return }
            let alert = NSAlert()
            alert.messageText = "Playback control unavailable"
            alert.informativeText = error
            let canOpen = selected != nil && selected == self.sourceKey && target != nil && target == self.snapshot.map(MediaSourceTarget.init)
            if canOpen { alert.addButton(withTitle: "Open Player") }
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn && canOpen { self.openPlayer?() }
        }
        switch route(command) {
        case .automatic: runner.send(command, completion: completion)
        case .application:
            if let target { selectedCommands.send(command, source: target, completion: completion) }
        case .native(let request): runner.send(command, target: request, completion: completion)
        case .unavailable: break
        }
    }

    func refreshOutputs() {
        let devices = AudioOutputDevice.devices()
        let current = AudioOutputDevice.defaultID()
        outputPicker.removeAllItems()
        if devices.isEmpty || !devices.contains(where: { $0.id == current }) {
            outputPicker.addItem(withTitle: "No audio output")
            outputPicker.lastItem?.isEnabled = false
        }
        for device in devices {
            // addItem(withTitle:) coalesces identical names; add distinct items so
            // two devices with the same display name can still be selected by UID.
            let item = NSMenuItem(title: device.name, action: nil, keyEquivalent: "")
            item.representedObject = device.uid
            item.image = JackIcon.image(named: "speaker.wave.2", accessibilityDescription: nil)
            outputPicker.menu?.addItem(item)
            if device.id == current { outputPicker.select(item) }
        }
        outputPicker.toolTip = "Audio output: \(outputPicker.titleOfSelectedItem ?? "unavailable"). Change where your Mac plays media."
        outputPicker.isEnabled = !devices.isEmpty
    }

    @objc private func selectOutput() {
        guard let uid = outputPicker.selectedItem?.representedObject as? String else { return }
        do { try AudioOutputDevice.select(uid: uid) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change audio output"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshOutputs()
    }

    func menuWillOpen(_ menu: NSMenu) { refreshOutputs(); menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // The selection action runs after the menu closes. Don't replace its
        // selected item until that action has read the UID.
        DispatchQueue.main.async { [weak self] in self?.refreshOutputs() }
    }
}

// Leave the bezel, tracking, keyboard and accessibility to NSButton. Its textured
// bezel can replace a template image's contentTintColor with the system accent.
// Draw the foreground separately so the visible glyph uses the waveform's ink.
private final class PlaybackTransportButton: NSButton {
    private let glyph: NSImage
    var glyphColor = PlaybackBars.emptyColor {
        didSet { if oldValue != glyphColor { needsDisplay = true } }
    }
    init(glyph: NSImage) {
        self.glyph = glyph
        super.init(frame: .zero)
        title = ""
        setButtonType(.momentaryPushIn)
        bezelStyle = .texturedRounded
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let size = glyph.size
        guard size.width > 0, size.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(19 / size.width, 13 / size.height)
        let width = size.width * scale, height = size.height * scale
        let rect = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        context.saveGState()
        if !isEnabled { context.setAlpha(0.45) }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        glyphColor.setFill()
        rect.fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
