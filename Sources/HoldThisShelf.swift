import AppKit
import Quartz

final class ShelfCollectionView: NSCollectionView {
    var itemMenu: ((IndexPath) -> NSMenu?)?
    var previewSelection: (() -> Void)?

    var openSelectedLinks: (() -> Bool)?

    func handleLinkReturn(_ event: NSEvent) -> Bool {
        guard [36, 76].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !selectionIndexPaths.isEmpty else { return false }
        if event.isARepeat { return true }
        return openSelectedLinks?() == true
    }

    override func keyDown(with event: NSEvent) {
        if handleLinkReturn(event) { return }
        guard event.charactersIgnoringModifiers == " ",
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !selectionIndexPaths.isEmpty else {
            super.keyDown(with: event)
            return
        }
        if !event.isARepeat { previewSelection?() }
    }

    private var controlClickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor = controlClickMonitor { NSEvent.removeMonitor(monitor) }
        controlClickMonitor = nil
        guard window != nil else { return }
        // Collection item labels can consume Control-click before it reaches the collection.
        controlClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.modifierFlags.contains(.control), event.window === self.window,
                  !self.isHiddenOrHasHiddenAncestor,
                  self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
                  let menu = self.menu(for: event) else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return nil
        }
    }

    deinit {
        if let monitor = controlClickMonitor { NSEvent.removeMonitor(monitor) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let path = indexPathForItem(at: point) else { return nil }
        selectionIndexPaths = [path]
        return itemMenu?(path)
    }
}

private final class TileSurface: NSView {
    var selected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (selected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.24)
                  : NSColor.controlBackgroundColor.withAlphaComponent(0.7)).setFill()
        path.fill()
        (selected ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
    }
}

private final class HeldThumbnail: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("HeldThumbnail")
    private let picture = NSImageView()
    private let pin = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let excerpt = NSTextField(wrappingLabelWithString: "")
    private(set) var itemID: UUID?
    var previewWork: Operation?

    override func loadView() {
        let tile = TileSurface()
        picture.imageScaling = .scaleProportionallyUpOrDown
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        excerpt.font = .systemFont(ofSize: 11)
        excerpt.isSelectable = false
        excerpt.maximumNumberOfLines = 3
        excerpt.lineBreakMode = .byTruncatingTail
        pin.image = JackIcon.image(named: "pin.fill", accessibilityDescription: nil)
        pin.contentTintColor = .white
        pin.imageScaling = .scaleProportionallyDown
        pin.wantsLayer = true
        pin.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.9).cgColor
        pin.layer?.cornerRadius = 9
        pin.setAccessibilityElement(false)
        for child in [picture, caption, excerpt, pin] {
            child.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(child)
        }
        NSLayoutConstraint.activate([
            pin.widthAnchor.constraint(equalToConstant: 18),
            pin.heightAnchor.constraint(equalToConstant: 18),
            pin.topAnchor.constraint(equalTo: tile.topAnchor, constant: 3),
            pin.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -3),
            caption.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 6),
            caption.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -6),
            caption.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -6),
            picture.topAnchor.constraint(equalTo: tile.topAnchor, constant: 6),
            picture.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -4),
            picture.leadingAnchor.constraint(equalTo: caption.leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: caption.trailingAnchor),
            excerpt.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 9),
            excerpt.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -9),
            excerpt.centerYAnchor.constraint(equalTo: picture.centerYAnchor),
            excerpt.heightAnchor.constraint(lessThanOrEqualTo: picture.heightAnchor)
        ])
        view = tile
    }

    override var isSelected: Bool {
        didSet { (view as? TileSurface)?.selected = isSelected }
    }

    func configure(_ item: HeldItem, url: URL?, image: NSImage?) {
        previewWork?.cancel()
        itemID = item.id
        view.toolTip = url?.path ?? item.value
        pin.isHidden = !item.isPinned
        view.setAccessibilityLabel(item.isPinned ? item.title + ", pinned" : item.title)
        (view as? TileSurface)?.selected = isSelected
        caption.stringValue = url?.lastPathComponent ?? item.title
        picture.isHidden = item.kind == .text
        excerpt.isHidden = item.kind != .text
        switch item.kind {
        case .file, .image:
            picture.image = image ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        case .link:
            picture.image = JackIcon.image(named: "link", accessibilityDescription: nil)
            caption.stringValue = URL(string: item.value)?.host ?? item.title
        case .text:
            excerpt.stringValue = String(item.value.prefix(240))
            caption.stringValue = "Text"
        }
    }

    func applyPreview(_ image: NSImage, for id: UUID) {
        if itemID == id { picture.image = image }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewWork?.cancel()
        itemID = nil
    }
}

final class HoldThisShelf: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSharingServicePickerDelegate, QLPreviewPanelDataSource {
    let store: HoldThisStore
    let view = NSStackView()
    private let collection = ShelfCollectionView()
    private let scroll = NSScrollView()
    private let header = NSStackView()
    private let loadErrorLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let removeButton = NSButton()
    private let thumbnails = NSCache<NSUUID, NSImage>()
    private let previewQueue = OperationQueue()
    private var items: [HeldItem] = []
    private var draggingIDs = Set<UUID>()
    private var sharePicker: NSSharingServicePicker?
    private var previewItems: [(id: UUID, url: URL)] = []
    private var websitePreview: HeldWebsitePreview?
    private weak var activePreviewPanel: QLPreviewPanel?
    var hasPreviewItems: Bool { !previewItems.isEmpty }

    init(store: HoldThisStore) {
        self.store = store
        super.init()
        thumbnails.countLimit = 150
        previewQueue.maxConcurrentOperationCount = 2
        previewQueue.qualityOfService = .utility

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 104, height: 72)
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.dataSource = self
        collection.delegate = self
        collection.previewSelection = { [weak self] in self?.togglePreview() }
        collection.openSelectedLinks = { [weak self] in
            guard let self else { return false }
            let links = self.selected.compactMap(\.websiteURL)
            guard !links.isEmpty else { return false }
            self.openWebsites(links)
            return true
        }
        collection.itemMenu = { [weak self] path in
            guard let self, self.items.indices.contains(path.item) else { return nil }
            self.updateActions()
            let item = self.items[path.item]
            return HeldItemMenu(item: item, store: self.store, reportError: { [weak self] in self?.present($0) },
                                showSharePicker: { [weak self] payload in self?.share(payload, from: item.id) })
        }
        collection.register(HeldThumbnail.self, forItemWithIdentifier: HeldThumbnail.reuseID)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)
        collection.registerForDraggedTypes(HoldThisStore.dropTypes)
        collection.setAccessibilityLabel("Held items")
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = collection

        let title = NSTextField(labelWithString: "Hold This")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.spacing = 6
        for (button, label, action) in [(copyButton, "Copy", #selector(copySelected)), (removeButton, "Remove", #selector(removeSelected))] {
            button.title = label
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label + " held items")
        }
        for child in [title, space, copyButton, removeButton] { header.addArrangedSubview(child) }
        loadErrorLabel.font = .systemFont(ofSize: 12)
        loadErrorLabel.textColor = .secondaryLabelColor
        loadErrorLabel.stringValue = store.loadError?.localizedDescription ?? ""
        loadErrorLabel.isHidden = store.loadError == nil
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 4
        for child in [header, scroll, loadErrorLabel] { view.addArrangedSubview(child) }
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: view.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: view.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 92)
        ])
        refresh()
    }

    private func openWebsites(_ urls: [URL]) {
        NativeLocationOpener.openWebsites(urls) { [weak self] result in
            if case .failure(let error) = result { self?.present(error) }
        }
    }

    private func togglePreview() {
        let selection = selected
        guard !selection.isEmpty, let anchor = view.window else { return }
        let sameWebSelection = websitePreview?.items.map(\.id) == selection.map(\.id)
        websitePreview?.close()
        if sameWebSelection { return }
        if selection.contains(where: { $0.websiteURL != nil }) {
            closePreview()
            do {
                let items = try selection.map { ($0.id, try store.previewURL(for: $0)) }
                let preview = HeldWebsitePreview(items: items, anchor: anchor) { [weak self] url in self?.openWebsites([url]) }
                websitePreview = preview
                preview.didClose = { [weak self] in self?.websitePreview = nil }
                preview.makeKeyAndOrderFront(nil)
            } catch { present(error) }
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        if activePreviewPanel?.isVisible == true && previewItems.map(\.id) == selection.map(\.id) {
            panel.close()
            return
        }
        do {
            previewItems = try selection.map { ($0.id, try store.previewURL(for: $0)) }
        } catch {
            present(error)
            return
        }
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        if activePreviewPanel === panel {
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
    }

    func beginPreview(_ panel: QLPreviewPanel) {
        activePreviewPanel = panel
        panel.dataSource = self
    }

    func endPreview(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        activePreviewPanel = nil
        previewItems.removeAll()
    }

    func closePreview() {
        websitePreview?.close()
        if let panel = activePreviewPanel, panel.isVisible { panel.close() }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewItems.indices.contains(index) else { return nil }
        return previewItems[index].url as NSURL
    }

    private func share(_ payload: [Any], from id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let anchor = collection.item(at: IndexPath(item: index, section: 0))?.view ?? view
        let picker = NSSharingServicePicker(items: payload)
        sharePicker = picker
        picker.delegate = self
        // Present on the shelf after the transient context menu has closed.
        DispatchQueue.main.async {
            guard anchor.window != nil else { return }
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        }
    }

    func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if sharePicker === picker { sharePicker = nil }
    }

    func accepts(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSCollectionView) !== collection && info.draggingSourceOperationMask.contains(.copy)
            && info.draggingPasteboard.availableType(from: HoldThisStore.dropTypes) != nil && store.loadError == nil
    }
    func receive(_ info: NSDraggingInfo) -> Bool {
        guard accepts(info) else { return false }
        do { try store.accept(info.draggingPasteboard); return true }
        catch { present(error); return false }
    }
    func present(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert(error: error)
            alert.messageText = "Hold This"
            alert.runModal()
        }
    }

    private var selected: [HeldItem] {
        collection.selectionIndexPaths.sorted().compactMap { path in
            items.indices.contains(path.item) ? items[path.item] : nil
        }
    }

    @discardableResult func refresh() -> Bool {
        let oldSelection = Set(selected.map(\.id))
        let added = store.items.count > items.count
        items = store.items.filter(\.isPinned) + store.items.filter { !$0.isPinned }
        if (websitePreview?.items ?? previewItems).contains(where: { preview in !items.contains { $0.id == preview.id } }) {
            closePreview()
        }
        collection.reloadData()
        collection.selectionIndexPaths = Set(items.indices.compactMap {
            oldSelection.contains(items[$0].id) ? IndexPath(item: $0, section: 0) : nil
        })
        if added, let firstNew = items.firstIndex(where: { !$0.isPinned }) {
            collection.scrollToItems(at: [IndexPath(item: firstNew, section: 0)], scrollPosition: .left)
        }
        view.isHidden = items.isEmpty && store.loadError == nil
        header.isHidden = items.isEmpty
        scroll.isHidden = items.isEmpty
        updateActions()
        return added
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let tile = collectionView.makeItem(withIdentifier: HeldThumbnail.reuseID, for: indexPath) as! HeldThumbnail
        let item = items[indexPath.item]
        let url = store.fileURL(for: item)
        let cached = thumbnails.object(forKey: item.id as NSUUID)
        tile.configure(item, url: url, image: cached)
        if let url, cached == nil {
            let work = BlockOperation()
            work.addExecutionBlock { [weak work, weak tile, weak self] in
                guard work?.isCancelled == false,
                      let image = ClipboardCapture.fileThumbnail(url, maxPixels: 192, maxBytes: item.kind == .image ? nil : 67_108_864) else { return }
                DispatchQueue.main.async {
                    self?.thumbnails.setObject(image, forKey: item.id as NSUUID)
                    tile?.applyPreview(image, for: item.id)
                }
            }
            tile.previewWork = work
            previewQueue.addOperation(work)
        }
        return tile
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateActions() }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateActions() }

    private func updateActions() {
        let enabled = !collection.selectionIndexPaths.isEmpty
        copyButton.isEnabled = enabled
        removeButton.isEnabled = enabled
    }
    @objc private func copySelected() {
        let selection = selected
        let writers = selection.compactMap(store.writer)
        guard !selection.isEmpty else { return }
        guard writers.count == selection.count else { showHint("An original file is unavailable on this Mac."); return }
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.writeObjects(writers) { showHint("The selected items could not be copied.") }
    }
    private func showHint(_ message: String) {
        present(NSError(domain: "AppleJack.HoldThis", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    @objc private func removeSelected() { remove(Set(selected.map(\.id))) }
    private func remove(_ ids: Set<UUID>) {
        do { try store.remove(ids) } catch { present(error) }
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        indexPaths.allSatisfy { path in
            guard let url = store.fileURL(for: items[path.item]) else { return true }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        store.writer(for: items[indexPath.item])
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        draggingIDs = Set(indexPaths.map { items[$0.item].id })
    }
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        if operation.contains(.copy), HoldThisStore.removesAfterDrag {
            do { try store.releaseAfterDrag(draggingIDs) } catch { present(error) }
        }
        draggingIDs.removeAll()
    }
    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo, proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        accepts(draggingInfo) ? .copy : []
    }
    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool { receive(draggingInfo) }
}
