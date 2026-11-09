import AppKit

final class FavoritesController: NSObject, NSMenuDelegate, NSMenuItemValidation, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let store: FavoritesStore
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    weak var heldSource: HoldThisStore?
    private let reorderType = NSPasteboard.PasteboardType("com.fonz.applejack.favorite-row")
    var canOpen: (() -> Bool)?
    var busyChanged: (() -> Void)?
    private(set) var isBusy = false
    private let runner: ShortcutRunner
    private var panel: NSPanel?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "Saved on this Mac")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let up = NSButton(title: "Move Up", target: nil, action: nil)
    private let down = NSButton(title: "Move Down", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Shortcut", target: nil, action: nil)
    private var shown: [JackFavorite] = []
    private var editing = false
    var preventsInstallation: Bool { isBusy || editing }
    private var selected: JackFavorite? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil }

    init(store: FavoritesStore = FavoritesStore(), runner: ShortcutRunner = ShortcutRunner()) {
        self.store = store; self.runner = runner
        super.init()
        button.menu = makeMenu(popup: true)
        button.toolTip = "Open a saved favorite."
        button.setAccessibilityLabel("Favorites")
        store.didChange = { [weak self] in self?.refresh() }
    }
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Favorites", action: nil, keyEquivalent: "")
        item.submenu = makeMenu(popup: false); return item
    }
    private func makeMenu(popup: Bool) -> NSMenu {
        let menu = NSMenu(title: "Favorites"); menu.delegate = self
        if popup { menu.addItem(withTitle: "Favorites", action: nil, keyEquivalent: "") }
        menu.addItem(action("Manage Favorites…", #selector(show)))
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        let popup = menu === button.menu
        menu.removeAllItems()
        if popup { menu.addItem(withTitle: "Favorites", action: nil, keyEquivalent: "") }
        for kind in JackFavorite.Kind.allCases {
            let entries = store.entries.filter { $0.kind == kind }
            let category = NSMenuItem(title: kind.title + "s", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: category.title)
            for entry in entries {
                let item = action(entry.name, #selector(openMenuFavorite(_:)))
                item.representedObject = entry.id.uuidString
                item.image = JackIcon.image(named: entry.kind.symbol, accessibilityDescription: entry.kind.title)
                item.image?.size = NSSize(width: 16, height: 16)
                // macOS 27 otherwise hides menu images in its automatic mode.
                if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
                item.setAccessibilityLabel("\(entry.name), \(entry.kind.title)")
                submenu.addItem(item)
            }
            if entries.isEmpty {
                let empty = NSMenuItem(title: store.loadError == nil ? "No saved " + category.title.lowercased() : "Couldn’t load favorites", action: nil, keyEquivalent: "")
                submenu.addItem(empty)
            }
            category.submenu = submenu; menu.addItem(category)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "Add Favorite", action: nil, keyEquivalent: "")
        let options = NSMenu(title: "Add Favorite")
        for kind in JackFavorite.Kind.addable {
            let item = action("\(kind.title)…", #selector(addFavorite(_:))); item.representedObject = kind.rawValue; options.addItem(item)
        }
        add.submenu = options; menu.addItem(add)
        menu.addItem(action("Manage Favorites…", #selector(show)))
    }
    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; return item
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openMenuFavorite(_:)) { return !isBusy && !editing && (canOpen?() ?? true) }
        if item.action == #selector(addFavorite(_:)) { return store.loadError == nil && !editing && store.entries.count < FavoritesStore.limit }
        return !editing
    }
    @objc private func openMenuFavorite(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value), let entry = store.entries.first(where: { $0.id == id }) else { return }
        if entry.kind == .item {
            guard !isBusy, !editing, canOpen?() ?? true else { return }
            let url = entry.localURL
            guard FileManager.default.fileExists(atPath: url.path) else { showError("This item is unavailable on this Mac."); return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            open(entry)
        }
    }
    @objc private func addFavorite(_ sender: NSMenuItem) {
        guard !editing, store.loadError == nil, let raw = sender.representedObject as? String, let kind = JackFavorite.Kind(rawValue: raw) else { return }
        edit(kind: kind, original: nil)
    }
    private func edit(kind: JackFavorite.Kind, original: JackFavorite?) {
        editing = true; refreshButtons(); busyChanged?()
        NSApp.activate(ignoringOtherApps: true)
        let editor = FavoritesEditor(kind: kind, original: original)
        var savedID: UUID?
        editor.present(save: { entry in try self.store.save(entry); savedID = entry.id }) { [self] saved in
            editing = false; refreshButtons(); busyChanged?()
            if saved {
                search.stringValue = ""; refresh()
                if let index = shown.firstIndex(where: { $0.id == savedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
                status.stringValue = "Favorite saved · \(store.entries.count) / \(FavoritesStore.limit) · This Mac"
            }
        }
    }
    @objc func show() {
        if panel == nil { build() }
        refreshAppearance()
        setLevel(UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true ? .floating : .normal)
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        if let nav = BubbleNavigation.current, let panel { nav.show(panel, title: "Manage Favorites") }
        else { panel?.makeKeyAndOrderFront(nil) }
    }
    func refreshAppearance() { panel?.appearance = NSApp.appearance; table.reloadData() }
    func setLevel(_ level: NSWindow.Level) { panel?.level = level }
    func refreshButtons() {
        guard panel != nil else { return }
        let entry = selected
        openButton.title = entry?.kind == .shortcut ? "Run" : "Open"
        openButton.isEnabled = entry != nil && !editing && !isBusy && (canOpen?() ?? true)
        editButton.isEnabled = entry != nil && !editing && store.loadError == nil
        removeButton.isEnabled = editButton.isEnabled
        up.isEnabled = !editing && search.stringValue.isEmpty && entry.map { store.canMove(id: $0.id, by: -1) } == true
        down.isEnabled = !editing && search.stringValue.isEmpty && entry.map { store.canMove(id: $0.id, by: 1) } == true
        cancelButton.isHidden = !runner.isActive
    }
    private func refresh() {
        let id = selected?.id
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        shown = store.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.destination.localizedCaseInsensitiveContains(query) || $0.kind.title.localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let index = shown.firstIndex(where: { $0.id == id }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        status.stringValue = store.loadError ?? (store.entries.isEmpty ? "Add a favorite to get started. Saved on this Mac." : "\(store.entries.count) / \(FavoritesStore.limit) favorites · Saved on this Mac")
        status.toolTip = store.loadError
        refreshButtons()
    }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshButtons() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard shown.indices.contains(row) else { return nil }
        let entry = shown[row]
        let cell = NSTableCellView()
        let icon = NSImageView(image: JackIcon.image(named: entry.kind.symbol, accessibilityDescription: entry.kind.title)!)
        let name = NSTextField(labelWithString: entry.name); name.font = .boldSystemFont(ofSize: 13)
        let detail = NSTextField(labelWithString: "\(entry.kind.title) · \(entry.destination)"); detail.font = .systemFont(ofSize: 11); detail.textColor = .secondaryLabelColor
        for label in [name, detail] { label.lineBreakMode = .byTruncatingMiddle; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        let labels = NSStackView(views: [name, detail]); labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        let rowView = NSStackView(views: [icon, labels]); rowView.spacing = 10; rowView.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        cell.addSubview(rowView); cell.textField = name; cell.imageView = icon
        NSLayoutConstraint.activate([rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), rowView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.toolTip = entry.destination; return cell
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard !editing, shown.indices.contains(row) else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(shown[row].id.uuidString, forType: reorderType)
        return writer
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard !editing, store.loadError == nil else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        if info.draggingSource as? NSTableView === tableView { return .move }
        return store.entries.count < FavoritesStore.limit && info.draggingPasteboard.availableType(from: HoldThisStore.dropTypes) != nil ? .copy : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard !editing, store.loadError == nil else { return false }
        let before = shown.indices.contains(row) ? shown[row].id : nil
        do {
            if info.draggingSource as? NSTableView === tableView {
                guard let raw = info.draggingPasteboard.string(forType: reorderType), let id = UUID(uuidString: raw) else { return false }
                try store.move(id: id, before: before)
                return true
            }
            return try addDrop(info.draggingPasteboard, before: before)
        } catch {
            status.stringValue = error.localizedDescription
            return false
        }
    }

    private func addDrop(_ board: NSPasteboard, before anchor: UUID?) throws -> Bool {
        // Decode the same formats as Hold This without putting the drop on Jack's shelf.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Jack-Favorites-" + UUID().uuidString)
        let incoming = HoldThisStore(directory: folder)
        var handled = Set<UUID>()
        var added = 0
        var failed = [String]()
        incoming.changed = { [weak self, weak incoming] in
            guard let self, let incoming else { return }
            for item in incoming.items where handled.insert(item.id).inserted {
                do {
                    var favorite = item
                    var source = incoming
                    // Hold This may release its own stored image after the drop.
                    if let held = self.heldSource, item.kind == .file, let url = incoming.fileURL(for: item),
                       let original = held.items.first(where: { $0.payloadFolder != nil && held.fileURL(for: $0)?.standardizedFileURL == url.standardizedFileURL }) {
                        favorite = original
                        source = held
                    }
                    try self.store.addHeld(favorite, from: source)
                    added += 1
                    try self.store.move(id: favorite.id, before: anchor)
                } catch { failed.append(error.localizedDescription) }
            }
        }
        incoming.deliveryError = { failed.append($0.localizedDescription) }
        do {
            try incoming.accept(board) { [weak self] in
                try? FileManager.default.removeItem(at: folder)
                self?.status.stringValue = failed.isEmpty ? (added == 1 ? "Added 1 favorite." : "Added \(added) favorites.") :
                    "Added \(added). " + (failed.first ?? "")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return added > 0 || failed.isEmpty
    }

    @objc private func openSelected() { if let selected { open(selected) } }
    @objc private func editSelected() { if let selected, !editing { edit(kind: selected.kind, original: selected) } }
    @objc private func removeSelected() {
        guard let entry = selected, !editing else { return }
        let alert = NSAlert(); alert.messageText = "Remove “\(entry.name)” from Favorites?"
        alert.informativeText = "This only removes the favorite. The original \(entry.kind.title.lowercased()) stays where it is."
        if URL(fileURLWithPath: entry.destination).deletingLastPathComponent().path == store.ownedFolder(for: entry.id).path {
            alert.informativeText = "This removes the copy saved in Favorites."
        }
        alert.addButton(withTitle: "Remove Favorite"); alert.addButton(withTitle: "Cancel")
        alert.presentInJack { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            do { try store.remove(id: entry.id) } catch { showError(error.localizedDescription) }
        }
    }
    @objc private func moveUp() { move(-1) }
    @objc private func moveDown() { move(1) }
    private func move(_ offset: Int) { guard let selected else { return }; do { try store.move(id: selected.id, by: offset) } catch { showError(error.localizedDescription) } }
    private func open(_ entry: JackFavorite) {
        guard !isBusy, !editing, canOpen?() ?? true else { return }
        isBusy = true; status.stringValue = entry.kind == .shortcut ? "Running \(entry.name)…" : "Opening \(entry.name)…"
        refreshButtons(); busyChanged?()
        let complete: (String?) -> Void = { [weak self] error in
            guard let self = self else { return }
            self.isBusy = false; self.refreshButtons(); self.busyChanged?()
            self.status.stringValue = error == nil ? (entry.kind == .shortcut ? "Shortcut finished." : "Opened \(entry.name).") : "Couldn’t open \(entry.name)."
            if let error { self.showError(error) }
        }
        switch entry.kind {
        case .shortcut:
            runner.run(shortcut: entry.destination, ignoringUserCancellation: true, completion: complete)
            refreshButtons()
        case .website:
            guard case .website(let url, _) = LocationOpenRequest.parse(entry.destination) else { complete("Edit this favorite to choose a valid website."); return }
            NativeLocationOpener.openWebsites([url]) { outcome in complete(outcome.failureDescription) }
        case .item:
            let url = entry.localURL
            guard FileManager.default.fileExists(atPath: url.path) else { complete("This item is unavailable on this Mac."); return }
            NSWorkspace.shared.open(url, configuration: .init()) { _, error in
                DispatchQueue.main.async { complete(error?.localizedDescription) }
            }
        case .folder:
            let url = entry.localURL
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map({ $0.isDirectory == true && $0.isPackage != true }) == true else {
                complete("This folder is unavailable. Connect its drive, or edit the favorite to choose its new location."); return
            }
            NativeLocationOpener.openFinder(url) { outcome in complete(outcome.failureDescription) }
        case .app:
            let app = InstalledApp(url: entry.localURL) ?? entry.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.flatMap { InstalledApp(url: $0) }
            guard let app else { complete("This app is unavailable. Edit the favorite to choose an installed app."); return }
            NativeAppLauncher.open(app) { outcome in complete(outcome.failureDescription) }
        }
    }
    @objc private func cancelShortcut() { cancel(); status.stringValue = "Shortcut canceled." }
    func cancel() { runner.cancel(); isBusy = false; refreshButtons(); busyChanged?() }
    private func showError(_ message: String) { let alert = NSAlert(); alert.messageText = "Favorites"; alert.informativeText = message; alert.presentInJack() }
    private func build() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 650, height: 330), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel = window; window.title = "Apple Jack Favorites"; window.contentMinSize = NSSize(width: 570, height: 270)
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false; window.center()
        let content = NSView(); window.contentView = content
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        search.placeholderString = "Search favorites"; search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("Search favorites")
        let add = NSPopUpButton(frame: .zero, pullsDown: true); add.addItem(withTitle: "Add Favorite")
        for kind in JackFavorite.Kind.addable { let item = action("\(kind.title)…", #selector(addFavorite(_:))); item.representedObject = kind.rawValue; add.menu?.addItem(item) }
        let header = NSStackView(views: [search, add]); header.spacing = 10; search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        table.addTableColumn(NSTableColumn(identifier: .init("favorite"))); table.headerView = nil; table.rowHeight = 46
        if #available(macOS 11, *) { table.style = .fullWidth }; table.delegate = self; table.dataSource = self; table.allowsEmptySelection = true
        table.target = self; table.doubleAction = #selector(openSelected); table.setAccessibilityLabel("Saved favorites")
        table.registerForDraggedTypes([reorderType] + HoldThisStore.dropTypes)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let scroll = FavoritesListScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let controls: [(NSButton, Selector)] = [(openButton,#selector(openSelected)),(editButton,#selector(editSelected)),(removeButton,#selector(removeSelected)),(up,#selector(moveUp)),(down,#selector(moveDown)),(cancelButton,#selector(cancelShortcut))]
        for (button, action) in controls { button.target = self; button.action = action }
        let buttons = NSStackView(views: controls.map { $0.0 }); buttons.spacing = 8
        stack.addArrangedSubview(buttons)
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

private extension Result where Failure == Error {
    var failureDescription: String? { if case .failure(let error) = self { return error.localizedDescription }; return nil }
}

// The table handles clicks, scrolling and row drags throughout its clip view,
// including the empty area after the last favorite.
final class FavoritesListScrollView: NSScrollView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === contentView || hit.isDescendant(of: contentView) { return documentView ?? hit }
        return hit
    }
    override func mouseDown(with event: NSEvent) {}
}
