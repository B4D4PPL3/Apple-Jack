import AppKit
import ImageIO

final class NowPlaying {
    let view = NowPlayingCard()
    private let sourceOpener = NowPlayingSourceOpener()
    private(set) var currentSource: MediaSourceTarget?
    private var catalog = MediaCatalogSnapshot(automatic: nil, sources: [])
    private var selectedKey: String?
    var selectionDidChange: ((String?, NowPlayingSnapshot?, String?) -> Void)?
    var isOpeningSource: Bool { sourceOpener.isBusy }
    private var process: Process?
    private var output: Pipe?
    private var generation = UUID()
    private var active = false
    private var showingCard = false
    private var retries = 0
    private var startupTimeout: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private let decoding = DispatchQueue(label: "com.fonz.applejack.now-playing", qos: .utility)

    init() {
        sourceOpener.currentTarget = { [weak self] in self?.currentSource }
        sourceOpener.busyDidChange = { [weak self] busy in self?.view.setOpeningSource(busy) }
        view.chooseSource = { [weak self] key in
            self?.selectedKey = key
            self?.renderSelection()
        }
        view.openSource = { [weak self] in self?.openCurrentSource() }
    }

    func openCurrentSource() {
        guard let source = currentSource else { return }
        sourceOpener.open(source)
    }

    func start(showCard: Bool = true) {
        guard !active || showingCard != showCard || (process == nil && retry == nil) else { return }
        showingCard = showCard
        view.setVisible(showCard)
        active = true
        retries = 0
        launch()
    }

    func stop() {
        active = false
        disconnect()
        view.setVisible(false)
    }

    private func disconnect() {
        generation = UUID()
        startupTimeout?.cancel(); startupTimeout = nil
        retry?.cancel(); retry = nil
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        currentSource = nil
        catalog = MediaCatalogSnapshot(automatic: nil, sources: [])
        selectionDidChange?(selectedKey, nil, nil)
    }

    private func launch() {
        guard active else { return }
        disconnect()
        if showingCard { view.showMessage("Now Playing", detail: "Checking your current player…") }
        let epoch = generation
        let child = Process()
        let pipe = Pipe()
        guard let resources = Bundle.main.resourceURL,
              let frameworks = Bundle.main.privateFrameworksURL else { failed(epoch); return }
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = [resources.appendingPathComponent("applejack-media.pl").path,
            frameworks.appendingPathComponent("MediaRemoteAdapter.framework").path,
            "catalog"]
        // No player titles, URLs or user input become executable arguments.
        child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8",
            "APPLEJACK_HOST_PID": String(ProcessInfo.processInfo.processIdentifier),
            "APPLEJACK_MEDIA_BADGE": showingCard ? "0" : "1"]
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let decoder = NowPlayingDecoder()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
            self?.decoding.async { [weak self] in
                do {
                    let updates = try decoder.appendCatalog(bytes)
                    // Coalesce a burst to its newest complete state; artwork is
                    // embedded data supplied by macOS, never a fetched URL.
                    guard let latest = updates.last else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, self.active, self.generation == epoch else { return }
                        self.startupTimeout?.cancel(); self.startupTimeout = nil
                        self.catalog = latest
                        self.renderSelection()
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in self?.failed(epoch) }
                }
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.failed(epoch) }
        }
        process = child
        output = pipe
        do {
            try child.run()
            let timeout = DispatchWorkItem { [weak self] in self?.failed(epoch) }
            startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
        } catch { failed(epoch) }
    }

    private func failed(_ epoch: UUID) {
        guard active, generation == epoch else { return }
        disconnect()
        view.showMessage("Now Playing unavailable", detail: "Media controls still work. Reopen the bubble to retry.")
        retries = min(3, retries + 1)
        let retry = DispatchWorkItem { [weak self] in self?.launch() }
        self.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + (retries <= 2 ? 3 : 60), execute: retry)
    }

    private func renderSelection() {
        let snapshot = catalog.selected(selectedKey)
        currentSource = snapshot.map(MediaSourceTarget.init)
        if showingCard {
            view.display(snapshot, image: snapshot?.artwork.flatMap(Self.thumbnail))
            if selectedKey != nil && snapshot == nil {
                view.showMessage("Selected source unavailable", detail: "Choose another source or Automatic.")
            }
            view.setSources(catalog.sources, selected: selectedKey, current: snapshot)
        }
        selectionDidChange?(selectedKey, snapshot, catalog.automatic?.sourceKey)
    }

    private static func thumbnail(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 144] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    deinit { disconnect() }
}

final class NowPlayingCard: NSView {
    var openSource: (() -> Void)?
    var chooseSource: ((String?) -> Void)?
    private let sourceButton = NSButton(title: "Automatic ▾", target: nil, action: nil)
    private var availableSources: [NowPlayingSnapshot] = []
    private var selectedKey: String?
    private var links: [NowPlayingLinkButton] = []
    private var canOpenSource = false
    private var openingSource = false
    private let artwork = NSImageView()
    private let title = NSTextField(labelWithString: "Nothing playing")
    private let subtitle = NSTextField(labelWithString: "Start music or a video to see it here.")
    private let status = NSTextField(labelWithString: "")
    private let bars = PlaybackBars()
    private var sourceID = ""
    private var sourceName = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.035, green: 0.055, blue: 0.045, alpha: 0.97).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(srgbRed: 0.64, green: 0.88, blue: 0.36, alpha: 0.25).cgColor
        heightAnchor.constraint(equalToConstant: 72).isActive = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Now Playing")
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.wantsLayer = true
        artwork.layer?.cornerRadius = 7
        artwork.layer?.masksToBounds = true
        artwork.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        artwork.contentTintColor = .lightGray
        if #available(macOS 11, *) { artwork.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular) }
        artwork.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.6)
        for field in [title, subtitle] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        status.font = .systemFont(ofSize: 10, weight: .medium)
        status.textColor = NSColor(srgbRed: 0.7, green: 0.95, blue: 0.4, alpha: 1)
        status.alignment = .center
        sourceButton.isBordered = false
        sourceButton.font = .systemFont(ofSize: 11)
        sourceButton.contentTintColor = NSColor.white.withAlphaComponent(0.65)
        sourceButton.target = self
        sourceButton.action = #selector(showSources)
        sourceButton.setAccessibilityLabel("Choose media source")
        sourceButton.setContentHuggingPriority(.required, for: .horizontal)
        sourceButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        subtitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for v in [artwork, title, subtitle, sourceButton, bars, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            artwork.centerYAnchor.constraint(equalTo: centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 48), artwork.heightAnchor.constraint(equalToConstant: 48),
            title.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -80),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            sourceButton.leadingAnchor.constraint(equalTo: subtitle.trailingAnchor, constant: 4),
            sourceButton.centerYAnchor.constraint(equalTo: subtitle.centerYAnchor),
            sourceButton.trailingAnchor.constraint(lessThanOrEqualTo: title.trailingAnchor),
            sourceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
            bars.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -21),
            bars.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            bars.widthAnchor.constraint(equalToConstant: 34), bars.heightAnchor.constraint(equalToConstant: 20),
            status.centerXAnchor.constraint(equalTo: bars.centerXAnchor),
            status.topAnchor.constraint(equalTo: bars.bottomAnchor, constant: 5),
            status.widthAnchor.constraint(equalToConstant: 60)
        ])
        for (content, label) in [(artwork as NSView, "Open playing source from artwork"),
                                 (title as NSView, "Open playing source from title"),
                                 (subtitle as NSView, "Open playing source from artist or channel")] {
            let button = NowPlayingLinkButton(title: "", target: self, action: #selector(revealSource))
            button.isBordered = false
            button.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            button.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            button.setAccessibilityLabel(label)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                button.topAnchor.constraint(equalTo: content.topAnchor),
                button.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            ])
            links.append(button)
        }
        display(nil, image: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVisible(_ visible: Bool) { bars.visible = visible }
    func setOpeningSource(_ opening: Bool) {
        openingSource = opening
        updateLinks()
    }
    private func updateLinks() {
        for link in links {
            link.isEnabled = canOpenSource && !openingSource
            link.window?.invalidateCursorRects(for: link)
        }
    }
    @objc private func revealSource() { if canOpenSource && !openingSource { openSource?() } }
    func display(_ snapshot: NowPlayingSnapshot?, image: NSImage?) {
        guard let snapshot = snapshot else {
            showMessage("Nothing playing", detail: "Start music or a video to see it here.")
            return
        }
        if sourceID != snapshot.bundleIdentifier {
            sourceID = snapshot.bundleIdentifier
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sourceID) {
                sourceName = app.deletingPathExtension().lastPathComponent
            } else { sourceName = "" }
        }
        title.stringValue = snapshot.title
        subtitle.stringValue = snapshot.artist.isEmpty ? "" : snapshot.artist + " ·"
        title.toolTip = snapshot.title
        subtitle.toolTip = subtitle.stringValue
        canOpenSource = !snapshot.bundleIdentifier.isEmpty
        let destination = sourceName.isEmpty ? "player" : sourceName
        for (index, link) in links.enumerated() {
            let content = index == 2 ? subtitle.stringValue : snapshot.title
            link.toolTip = "\(content)\nClick to show the source in \(destination)."
            link.setAccessibilityHelp("Show the existing playing source in \(destination)")
        }
        updateLinks()
        artwork.image = image ?? JackIcon.image(named: "music.note", accessibilityDescription: nil)
        status.stringValue = snapshot.playing ? "Playing" : "Paused"
        status.textColor = snapshot.playing ? NSColor(srgbRed: 0.7, green: 0.95, blue: 0.4, alpha: 1) : .lightGray
        bars.playing = snapshot.playing
    }
    func setSources(_ sources: [NowPlayingSnapshot], selected: String?, current: NowPlayingSnapshot?) {
        availableSources = sources
        selectedKey = selected
        let name = current.map { playerName($0.bundleIdentifier) } ?? (selected == nil ? "Automatic" : "Choose source")
        sourceButton.title = name + " ▾"
        sourceButton.toolTip = selected == nil ? "Automatic — follows your Mac’s current player. Click to choose." : "Selected: \(name). Click to change media source."
        sourceButton.setAccessibilityValue(selected == nil ? "Automatic" : name)
    }
    private func playerName(_ bundle: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)?.deletingPathExtension().lastPathComponent ?? "Media player"
    }
    @objc private func showSources() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let automatic = NSMenuItem(title: "Automatic", action: #selector(selectSource(_:)), keyEquivalent: "")
        automatic.target = self; automatic.state = selectedKey == nil ? .on : .off
        menu.addItem(automatic); menu.addItem(.separator())
        let sorted = availableSources.sorted { playerName($0.bundleIdentifier).localizedStandardCompare(playerName($1.bundleIdentifier)) == .orderedAscending }
        for source in sorted {
            let name = playerName(source.bundleIdentifier)
            let duplicate = sorted.filter { $0.bundleIdentifier == source.bundleIdentifier }.count > 1
            let label = duplicate ? name + " — " + String(source.title.prefix(55)) : name
            let item = NSMenuItem(title: label, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = source.sourceKey
            item.state = selectedKey == source.sourceKey ? .on : .off
            item.isEnabled = true
            item.toolTip = source.title + (source.playing ? " (Playing)" : " (Paused)")
            menu.addItem(item)
        }
        if sorted.isEmpty {
            let empty = NSMenuItem(title: "No active media sources", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sourceButton.bounds.height + 4), in: sourceButton)
    }
    @objc private func selectSource(_ item: NSMenuItem) { chooseSource?(item.representedObject as? String) }

    func showMessage(_ message: String, detail: String) {
        canOpenSource = false; updateLinks()
        links.forEach { $0.toolTip = nil }
        title.stringValue = message
        subtitle.stringValue = detail
        title.toolTip = nil; subtitle.toolTip = nil
        artwork.image = JackIcon.image(named: "music.note", accessibilityDescription: nil)
        status.stringValue = ""
        bars.playing = false
    }
}

// Transparent native buttons preserve the card’s design while supporting
// keyboard activation, VoiceOver, a hand cursor, and pressed feedback.
final class NowPlayingLinkButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.white.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
    }
}

// Decorative pixel bars indicate reported playback state, not measured audio.
// No audio capture is used, and the timer stops with the bubble or playback.
final class PlaybackBars: NSView {
    var playing = false { didSet { updateTimer() } }
    var visible = false { didSet { if oldValue != visible { updateTimer() } } }
    var playingColor = NSColor(srgbRed: 0.68, green: 0.94, blue: 0.35, alpha: 1)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var timer: Timer?
    private var motionObserver: NSObjectProtocol?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateTimer() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateTimer() {
        let animate = playing && visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate && timer == nil {
            let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in self?.needsDisplay = true }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !animate { timer?.invalidate(); timer = nil }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let time = timer == nil ? 0 : ProcessInfo.processInfo.systemUptime
        for column in 0..<6 {
            let level = playing ? 1 + Int((sin(time * 5 + Double(column) * 1.6) + 1) * 2) : 1
            for row in 0..<level {
                (playing ? playingColor : NSColor.gray).setFill()
                NSRect(x: column * 6, y: row * 4, width: 4, height: 3).fill()
            }
        }
    }
    deinit {
        timer?.invalidate()
        if let motionObserver = motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }
}
