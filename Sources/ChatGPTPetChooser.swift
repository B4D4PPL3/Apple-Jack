import AppKit

final class ChatGPTPetChooser: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Choice { case pet(ChatGPTPetCandidate), file, cancel }
    private var candidates: [ChatGPTPetCandidate]
    private let status = NSTextField(labelWithString: "Checking your ChatGPT account for custom pets…")
    private let previewStatus = NSTextField(labelWithString: "")
    private var generation = 0
    private var userSelected = false
    private var updating = false
    private let list = NSTableView()
    private let preview = NSImageView()
    private let previews = OperationQueue()
    private let dialog = NSAlert()

    init(_ candidates: [ChatGPTPetCandidate]) {
        self.candidates = candidates
        super.init()
        dialog.messageText = "Import ChatGPT Pet"
        dialog.informativeText = "Select a pet to preview and import, or choose a downloaded sprite sheet."
        dialog.addButton(withTitle: "Import").isEnabled = !candidates.isEmpty
        dialog.addButton(withTitle: "Choose File…")
        dialog.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 418, height: 252))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 42, width: 272, height: 210))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        list.headerView = nil
        list.rowHeight = 24
        list.allowsEmptySelection = false
        list.setAccessibilityLabel("Available ChatGPT pets")
        for (id, width) in [("Pet", 165.0), ("Source", 70.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = id
            column.width = width
            list.addTableColumn(column)
        }
        list.dataSource = self
        list.delegate = self
        scroll.documentView = list
        content.addSubview(scroll)
        preview.frame = NSRect(x: 282, y: 76, width: 132, height: 148)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityElement(false)
        content.addSubview(preview)
        previewStatus.frame = NSRect(x: 276, y: 130, width: 140, height: 32)
        previewStatus.alignment = .center
        previewStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        previewStatus.textColor = .secondaryLabelColor
        content.addSubview(previewStatus)
        status.frame = NSRect(x: 2, y: 0, width: 410, height: 38)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        content.addSubview(status)
        dialog.accessoryView = content
        previews.maxConcurrentOperationCount = 1
        previews.qualityOfService = .userInitiated
        list.reloadData()
        updating = true
        if !candidates.isEmpty { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updating = false
        showPreview()
        dialog.window.initialFirstResponder = list
    }

    func run() -> Choice {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cloud = Result { try ChatGPTAccountPets.list() }
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in self?.apply(cloud) }
        }
        defer { previews.cancelAllOperations() }
        switch dialog.runModal() {
        case .alertFirstButtonReturn where candidates.indices.contains(list.selectedRow): return .pet(candidates[list.selectedRow])
        case .alertSecondButtonReturn: return .file
        default: return .cancel
        }
    }

    private func apply(_ cloud: Result<[ChatGPTPetCandidate], Error>) {
        switch cloud {
        case .failure:
            status.stringValue = "Account pets are unavailable. Check your ChatGPT sign-in and connection, or choose a file."
        case .success(let pets):
            let merged = ChatGPTPetCatalog.merged(local: candidates, account: pets)
            status.stringValue = merged.isEmpty ? "No pets found. Choose a downloaded sprite sheet to import." : ""
            guard merged.count > candidates.count else { return }
            let previousID = candidates.indices.contains(list.selectedRow) ? candidates[list.selectedRow].id : nil
            let row = userSelected ? merged.firstIndex(where: { $0.id == previousID }) ?? 0 : 0
            candidates = merged
            updating = true
            list.reloadData()
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            list.scrollRowToVisible(row)
            updating = false
            dialog.buttons[0].isEnabled = true
            showPreview()
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let label = (list.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.lineBreakMode = .byTruncatingTail
        let isName = id.rawValue == "Pet"
        label.stringValue = isName ? candidates[row].name : candidates[row].sourceName
        label.textColor = isName ? .labelColor : .secondaryLabelColor
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        userSelected = true
        showPreview()
    }

    private func showPreview() {
        generation += 1
        let token = generation, row = list.selectedRow
        previews.cancelAllOperations()
        preview.image = nil
        previewStatus.stringValue = ""
        guard candidates.indices.contains(row) else { return }
        let pet = candidates[row]
        previewStatus.stringValue = "Loading preview…"
        previews.addOperation { [weak self] in
            let image = pet.preview()
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
                guard let self, self.generation == token else { return }
                self.preview.image = image.map { NSImage(cgImage: $0, size: .zero) }
                self.previewStatus.stringValue = image == nil ? "Preview unavailable" : ""
            }
        }
    }
}
