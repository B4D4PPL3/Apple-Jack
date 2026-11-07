import AppKit

private final class ClipboardPreviewBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // Resolve the semantic color in this view's appearance, including an
        // app override that differs from the Mac's current appearance.
        let fill = { [self] in
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
        }
        if #available(macOS 11, *) {
            effectiveAppearance.performAsCurrentDrawingAppearance(fill)
        } else {
            let previous = NSAppearance.current
            NSAppearance.current = effectiveAppearance
            defer { NSAppearance.current = previous }
            fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// The image fits the pane; its pixel dimensions must never enlarge the window.
private final class ClipboardImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

private final class ClipboardTable: NSTableView {
    var copySelection: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 || (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "c") {
            copySelection?(); return
        }
        super.keyDown(with: event)
    }
}

final class ClipboardWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextViewDelegate, NSWindowDelegate {
    static let frameAutosaveName = "AppleJackClipboardCompactWindow"
    static let defaultContentSize = NSSize(width: 780, height: 280)
    let history: ClipboardHistory
    var useText: ((String) -> Bool)?
    var runTextAction: ((ClipboardTextAction, String) -> Bool)?
    var canRunTextAction: (() -> Bool)?
    private var panel: NSPanel?
    private let table = ClipboardTable()
    private let search = NSSearchField()
    private let pause = NSButton()
    private let privacy = NSButton(title: "Privacy Settings…", target: nil, action: nil)
    private let filter = NSSegmentedControl(labels: ["All", "Pinned"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let image = ClipboardImageView()
    private let previewLoader = ClipboardPreviewLoader()
    private let imageHolder = ClipboardPreviewBackground()
    private let textScroll = NSScrollView()
    private let copyButton = NSButton()
    private let plainButton = NSButton()
    private let pinButton = NSButton()
    private let useButton = NSButton()
    private let deleteButton = NSButton()
    private let textActions = NSPopUpButton(frame: .zero, pullsDown: true)
    private var shown: [ClipboardEntry] = []
    private var reloading = false
    private var selected: ClipboardEntry? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil }
    init(history: ClipboardHistory) {
        self.history = history
        super.init()
        history.didChange = { [weak self] in self?.refresh() }
    }
    func show() {
        if panel == nil { build() }
        panel?.appearance = NSApp.appearance
        panel?.level = UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true ? .floating : .normal
        refresh()
        history.refreshExpiry()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        updatePreview()
        panel?.makeFirstResponder(search)
    }
    func close() { panel?.close() }
    func windowWillClose(_ notification: Notification) { previewLoader.cancel() }
    func refreshAppearance() { panel?.appearance = NSApp.appearance }
    func setLevel(_ level: NSWindow.Level) { panel?.level = level }
    private func build() {
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: Self.defaultContentSize), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Apple Jack Clipboard"
        window.delegate = self
        window.contentMinSize = NSSize(width: 690, height: 260)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        // Give existing installs the compact default once. Preserve the old
        // position, then remember subsequent user resizing under the new key.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            if window.setFrameUsingName("AppleJackClipboardWindow") {
                let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
                window.setContentSize(Self.defaultContentSize)
                window.setFrameTopLeftPoint(topLeft)
            } else { window.center() }
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        // A saved frame on a disconnected display should not strand history.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        let background = NSVisualEffectView(); background.material = .underWindowBackground; background.blendingMode = .behindWindow; background.state = .active
        window.contentView = background
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 8; stack.alignment = .leading; stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -14), stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12)])
        let header = NSStackView(); header.spacing = 10
        let icon = NSImageView(image: JackIcon.image(named: "doc.on.clipboard.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemGreen; header.addArrangedSubview(icon)
        let heading = NSTextField(labelWithString: "Clipboard"); heading.font = .boldSystemFont(ofSize: 20); header.addArrangedSubview(heading)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal); header.addArrangedSubview(spacer)
        pause.target = self; pause.action = #selector(toggleCapture); pause.bezelStyle = .rounded; header.addArrangedSubview(pause)
        privacy.target = self; privacy.action = #selector(openPrivacy); privacy.isHidden = true; header.addArrangedSubview(privacy)
        let clear = NSButton(title: "Clear…", target: self, action: #selector(clearHistory)); header.addArrangedSubview(clear)
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        header.heightAnchor.constraint(equalToConstant: 28).isActive = true
        search.placeholderString = "Search copied text, files, or apps"; search.delegate = self
        search.setAccessibilityLabel("Search clipboard history")
        search.sendsSearchStringImmediately = true
        filter.selectedSegment = 0; filter.target = self; filter.action = #selector(filterChanged)
        let searchRow = NSStackView(views: [search, filter]); searchRow.spacing = 10
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(searchRow); searchRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        searchRow.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let column = NSTableColumn(identifier: .init("clip")); column.title = "Clipboard history"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 44; table.intercellSpacing = NSSize(width: 0, height: 2)
        if #available(macOS 11, *) { table.style = .fullWidth }; table.backgroundColor = .clear; table.delegate = self; table.dataSource = self
        table.allowsEmptySelection = true; table.target = self; table.doubleAction = #selector(copyAndClose)
        table.setAccessibilityLabel("Saved clipboard items")
        table.copySelection = { [weak self] in self?.copySelected() }
        let listScroll = NSScrollView(); listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.drawsBackground = false
        let right = NSStackView(); right.orientation = .vertical; right.spacing = 6; right.alignment = .leading; right.distribution = .fill
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor; detail.maximumNumberOfLines = 2
        right.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        detail.heightAnchor.constraint(equalToConstant: 32).isActive = true
        imageHolder.wantsLayer = true; imageHolder.layer?.cornerRadius = 10; imageHolder.layer?.masksToBounds = true
        textScroll.hasVerticalScroller = true; textScroll.drawsBackground = false; textScroll.borderType = .noBorder
        preview.isEditable = false; preview.isSelectable = true; preview.drawsBackground = false
        preview.delegate = self
        preview.textColor = .textColor
        preview.font = .systemFont(ofSize: 14); preview.textContainerInset = NSSize(width: 12, height: 12)
        preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        textScroll.documentView = preview
        image.imageScaling = .scaleProportionallyUpOrDown
        image.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        image.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for child in [textScroll, image] { child.translatesAutoresizingMaskIntoConstraints = false; imageHolder.addSubview(child); NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: imageHolder.leadingAnchor),child.trailingAnchor.constraint(equalTo: imageHolder.trailingAnchor),child.topAnchor.constraint(equalTo: imageHolder.topAnchor),child.bottomAnchor.constraint(equalTo: imageHolder.bottomAnchor)]) }
        right.addArrangedSubview(imageHolder); imageHolder.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        imageHolder.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        let content = NSStackView(views: [listScroll, right]); content.orientation = .horizontal; content.alignment = .top; content.spacing = 14
        stack.addArrangedSubview(content); content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([listScroll.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.44), listScroll.heightAnchor.constraint(equalTo: content.heightAnchor), right.heightAnchor.constraint(equalTo: content.heightAnchor), right.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.56, constant: -14), imageHolder.bottomAnchor.constraint(equalTo: right.bottomAnchor)])
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageHolder.setContentHuggingPriority(.defaultLow, for: .vertical)
        let actions = NSStackView(); actions.spacing = 8
        for (button, title, action) in [(copyButton,"Copy",#selector(copySelected)), (plainButton,"Copy Plain Text",#selector(copyPlain)), (useButton,"Use in Jack",#selector(insertInJack)), (pinButton,"Pin",#selector(togglePin)), (deleteButton,"Delete",#selector(deleteSelected))] {
            button.title = title; button.target = self; button.action = action; button.bezelStyle = .rounded; actions.addArrangedSubview(button)
        }
        copyButton.toolTip = "Copy the selected item, then use ⌘V in your app. Double-click a row to copy and close."
        useButton.toolTip = "Fill Jack’s input field without submitting it."
        textActions.addItem(withTitle: "Text Actions")
        textActions.menu?.autoenablesItems = false
        for action in ClipboardTextAction.allCases {
            let item = NSMenuItem(title: action.rawValue, action: #selector(performTextAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = action.rawValue
            textActions.menu?.addItem(item)
        }
        textActions.setAccessibilityLabel("Clipboard text actions")
        actions.addArrangedSubview(textActions)
        stack.addArrangedSubview(actions)
        actions.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        actions.heightAnchor.constraint(equalToConstant: 28).isActive = true
        status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 1; status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .systemFont(ofSize: 11); count.textColor = .tertiaryLabelColor
        count.toolTip = "Saved on this Mac. Unpinned items expire after 30 days."
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [status, count]); footer.spacing = 10
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        footer.heightAnchor.constraint(equalToConstant: 16).isActive = true
        panel = window
    }
    func refresh() {
        guard panel != nil else { return }
        let id = selected?.id
        let q = search.stringValue
        shown = history.entries.filter { $0.matches(q) && (filter.selectedSegment == 0 || $0.pinned) }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.date > $1.date
        }
        reloading = true
        table.reloadData()
        if let id, let index = shown.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        reloading = false
        pause.title = history.enabled ? "Pause History" : "Enable History"
        pause.isEnabled = history.ready
        privacy.isHidden = !history.status.contains("Clipboard access is restricted")
        count.stringValue = "\(history.entries.count) / 100 items"
        status.stringValue = history.status.isEmpty ? (history.enabled ? "Saving new copies. Marked confidential and temporary items are skipped." : "History is paused. Enable it to save future text, links, images, and file references.") : history.status
        status.toolTip = status.stringValue
        updatePreview()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let item = shown[row]
        let title = NSTextField(labelWithString: (item.pinned ? "📌 " : "") + item.title)
        title.font = .systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        let date = abs(item.date.timeIntervalSinceNow) < 60 ? "Just now" : RelativeDateTimeFormatter().localizedString(for: item.date, relativeTo: Date())
        let subtitle = NSTextField(labelWithString: "\(item.kind.rawValue.capitalized) · \(item.source) · \(date)")
        subtitle.font = .systemFont(ofSize: 11); subtitle.textColor = .secondaryLabelColor; subtitle.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView(); let labels = NSStackView(views: [title, subtitle]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(labels)
        NSLayoutConstraint.activate([labels.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),labels.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),title.widthAnchor.constraint(equalTo: labels.widthAnchor),subtitle.widthAnchor.constraint(equalTo: labels.widthAnchor)])
        cell.textField = title; cell.setAccessibilityLabel(item.title)
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !reloading { updatePreview() } }
    func controlTextDidChange(_ notification: Notification) {
        if let editor = search.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        refresh()
    }
    private func updatePreview() {
        let entry = selected
        previewLoader.cancel()
        for button in [copyButton, plainButton, useButton, pinButton, deleteButton] { button.isEnabled = entry != nil }
        plainButton.isEnabled = entry?.textRepresentation != nil; useButton.isEnabled = entry?.textRepresentation != nil
        if entry?.kind == .files {
            plainButton.toolTip = "Copy the file paths as text, one path per line."
            useButton.toolTip = "Fill Jack’s input with the file paths without submitting them."
        } else if entry?.kind == .text {
            plainButton.toolTip = "Copy text without formatting."
            useButton.toolTip = "Fill Jack’s input field without submitting it."
        } else {
            plainButton.toolTip = "This image has no file path. Use Copy to copy the image."
            useButton.toolTip = "This image has no file path or text to put in Jack’s input."
        }
        pinButton.title = entry?.pinned == true ? "Unpin" : "Pin"
        image.isHidden = true; textScroll.isHidden = false; image.image = nil
        image.toolTip = entry?.kind == .files ? entry?.text : nil
        if let entry {
            detail.stringValue = "\(entry.kind.rawValue.capitalized) · \(entry.source)\n\(DateFormatter.localizedString(from: entry.date, dateStyle: .medium, timeStyle: .short))"
            preview.string = String(entry.text.prefix(ClipboardTextAction.previewLimit)) + (entry.text.count > ClipboardTextAction.previewLimit ? "\n\n[Preview shortened. Copy retains the full text.]" : "")
            if entry.kind == .image { preview.string = "Loading image preview…" }
            if panel?.isVisible == true && (entry.kind == .image || (entry.kind == .files && entry.fileURLs.count == 1)) {
                previewLoader.load(entry) { [weak self] thumbnail in
                    guard let self, self.selected?.id == entry.id else { return }
                    self.image.image = thumbnail
                    self.image.setAccessibilityLabel("Image preview: \(entry.title)")
                    self.image.isHidden = thumbnail == nil
                    self.textScroll.isHidden = thumbnail != nil
                    if thumbnail == nil && entry.kind == .image { self.preview.string = "Image preview unavailable. Use Copy to copy the saved image." }
                }
            }
        } else {
            detail.stringValue = "Your copies, ready when you need them"
            preview.string = shown.isEmpty && !search.stringValue.isEmpty ? "No matching items." : "Copy something new after enabling history. Select an item to preview it here."
        }
        preview.scrollToBeginningOfDocument(nil)
        preview.setSelectedRange(NSRange(location: 0, length: 0))
        refreshActionAvailability()
    }
    func textViewDidChangeSelection(_ notification: Notification) { refreshActionAvailability() }
    func refreshActionAvailability() {
        guard panel != nil else { return }
        let source = ClipboardTextAction.source(in: selected, selection: preview.selectedRange())
        textActions.isEnabled = source != nil && runTextAction != nil && (canRunTextAction?() ?? true)
        textActions.toolTip = selected?.kind == .text
            ? "Summarize, rewrite, or explain with Jack’s selected AI. Highlight words in the preview to use only those words. Your draft is kept."
            : "Select a copied text item to summarize, rewrite, or explain it."
    }
    @objc private func performTextAction(_ sender: NSMenuItem) {
        guard canRunTextAction?() ?? true,
              let name = sender.representedObject as? String, let action = ClipboardTextAction(rawValue: name),
              let text = ClipboardTextAction.source(in: selected, selection: preview.selectedRange()) else { return }
        if runTextAction?(action, text) == true { close() }
    }
    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }
    @objc private func filterChanged() { refresh() }
    @objc private func toggleCapture() { history.setEnabled(!history.enabled) }
    @objc private func copySelected() { guard let entry = selected else { return }; history.copy(entry) { _ in } }
    @objc private func copyPlain() { guard let entry = selected, entry.textRepresentation != nil else { return }; history.copy(entry, plainText: true) { _ in } }
    @objc private func copyAndClose() { guard let entry = selected else { return }; history.copy(entry) { [weak self] ok in if ok { self?.close() } } }
    @objc private func togglePin() { if let entry = selected { history.togglePin(entry.id) } }
    @objc private func deleteSelected() { if let entry = selected { history.remove(entry.id) } }
    @objc private func insertInJack() { guard let text = selected?.textRepresentation else { return }; if useText?(text) == true { close() } }
    @objc private func clearHistory() {
        guard !history.entries.isEmpty, let panel else { return }
        let alert = NSAlert(); alert.messageText = "Clear clipboard history?"
        alert.informativeText = "This removes saved items on this Mac. The current system clipboard is kept. You can keep pinned items or clear everything."
        alert.addButton(withTitle: "Clear Unpinned"); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Clear All")
        alert.beginSheetModal(for: panel) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.history.clear(keepPinned: true) }
            else if response == .alertThirdButtonReturn { self?.history.clear(keepPinned: false) }
        }
    }
}
