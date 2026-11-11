import AppKit

/// Shared selection and preview for the installed library and ChatGPT importer.
final class PetPreviewList: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row {
        let name: String
        let source: String
        let preview: () -> CGImage?
    }

    let table = NSTableView()
    private let image = NSImageView()
    private let message = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var dividerBefore: Int?
    private let previews = OperationQueue()
    private var generation = 0
    private var reloading = false
    var onSelect: (() -> Void)?
    var selectedRow: Int { table.selectedRow }

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 418, height: 210))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 272, height: 210))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        table.headerView = nil
        table.rowHeight = 24
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(label)
        for (name, width) in [("Pet", 165.0), ("Source", 70.0)] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = name == "Pet" ? "Companion" : name
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        scroll.documentView = table
        addSubview(scroll)

        image.frame = NSRect(x: 282, y: 32, width: 132, height: 148)
        image.imageScaling = .scaleProportionallyUpOrDown
        addSubview(image)
        message.frame = NSRect(x: 276, y: 88, width: 142, height: 32)
        message.alignment = .center
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = .secondaryLabelColor
        addSubview(message)

        previews.maxConcurrentOperationCount = 1
        previews.qualityOfService = .userInitiated
    }
    required init?(coder: NSCoder) { fatalError() }

    func reload(_ rows: [Row], selecting preferred: Int?, dividerBefore: Int? = nil) {
        reloading = true
        self.rows = rows
        self.dividerBefore = dividerBefore
        table.reloadData()
        if !rows.isEmpty {
            let index = preferred.flatMap { rows.indices.contains($0) ? $0 : nil } ?? 0
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
        reloading = false
        loadPreview()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier else { return nil }
        let label = (table.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.lineBreakMode = .byTruncatingTail
        let isName = id.rawValue == "Pet"
        label.stringValue = isName ? rows[row].name : rows[row].source
        label.textColor = isName ? .labelColor : .secondaryLabelColor
        return label
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        row == dividerBefore ? PetDividerRow() : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        loadPreview()
        onSelect?()
    }

    func cancelPreview() {
        generation += 1
        previews.cancelAllOperations()
    }

    private func loadPreview() {
        cancelPreview()
        let token = generation
        image.image = nil
        image.setAccessibilityElement(false)
        message.stringValue = ""
        guard rows.indices.contains(selectedRow) else { return }
        let row = rows[selectedRow]
        message.stringValue = "Loading preview…"
        previews.addOperation { [weak self] in
            let result = row.preview()
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
                guard let self, self.generation == token else { return }
                self.image.image = result.map { NSImage(cgImage: $0, size: .zero) }
                self.image.setAccessibilityLabel(row.name + " preview")
                self.image.setAccessibilityElement(result != nil)
                self.message.stringValue = result == nil ? "Preview unavailable" : ""
            }
        }
    }
}

private final class PetDividerRow: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: isFlipped ? bounds.minY : bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}
