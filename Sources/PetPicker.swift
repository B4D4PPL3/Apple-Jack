import AppKit

final class PetPicker: NSObject, NSMenuItemValidation {
    typealias Sheets = [String: LoadedSpriteSheet]
    let library: ImportedPets
    init(library: ImportedPets = ImportedPets()) {
        self.library = library
        super.init()
    }

    private lazy var automatic: PetAutoImport = {
        let controller = PetAutoImport(library: library)
        controller.changed = { [weak self] in self?.refreshLibrary() }
        return controller
    }()
    func startAutomaticImports() { automatic.start() }

    private let selectionKey = "selectedImportedPet"
    private weak var page: PetLibraryPage?
    private(set) var isBusy = false { didSet { updateButtons() } }
    var canChange: () -> Bool = { false }
    var showSprites: ((Sheets) -> Void)?
    var selectedID: String? {
        let id = UserDefaults.standard.string(forKey: selectionKey)
        return id == BundledPet.appleJack.rawValue ? nil : id
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Companions", action: #selector(showPets), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showPets() {
        guard !isBusy, canChange(), let navigation = BubbleNavigation.current else { return }
        if page != nil { return }
        let view = PetLibraryPage()
        page = view
        view.list.onSelect = { [weak self] in self?.updateButtons() }
        for (button, action) in [(view.use, #selector(choose)), (view.add, #selector(importPet)),
                                 (view.remove, #selector(removeSelected)), (view.auto, #selector(toggleAutoImport))] {
            button.target = self
            button.action = action
        }
        refreshLibrary(selecting: selectedID ?? BundledPet.appleJack.rawValue)
        navigation.show("Companions", body: view, size: view.frame.size) { [weak self, weak view] in
            view?.list.cancelPreview()
            self?.page = nil
        }
    }

    private func updateButtons() {
        guard let page else { return }
        let pet = page.selection
        let current = pet?.id == (selectedID ?? BundledPet.appleJack.rawValue)
        page.use.title = current ? "In Use" : "Use Companion"
        page.use.isEnabled = !isBusy && pet != nil && !current
        page.add.isEnabled = !isBusy
        page.remove.isEnabled = !isBusy && pet.map { BundledPet(rawValue: $0.id) == nil } == true
        page.auto.isEnabled = !isBusy
        page.auto.state = automatic.isEnabled ? .on : .off
        page.status.stringValue = automatic.status ?? ""
    }

    @objc private func toggleAutoImport() { automatic.toggle() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !isBusy && canChange() }

    func remember(_ id: String?) {
        if let id, id != BundledPet.appleJack.rawValue { UserDefaults.standard.set(id, forKey: selectionKey) }
        else { UserDefaults.standard.removeObject(forKey: selectionKey) }
        refreshLibrary(selecting: id ?? BundledPet.appleJack.rawValue)
    }

    private func refreshLibrary(selecting id: String? = nil) {
        guard let page else { return }
        let pets = BundledPet.allCases.map { ImportedPet(id: $0.rawValue, name: $0.name) } + library.entries()
        if pets != page.choices || (id != nil && id != page.selection?.id) {
            let preferred = id ?? page.selection?.id ?? selectedID ?? BundledPet.appleJack.rawValue
            page.choices = pets
            let rows = pets.map { pet in
                PetPreviewList.Row(name: pet.name, source: BundledPet(rawValue: pet.id) == nil ? "Imported" : "Built-in",
                                   preview: { [library] in library.preview(pet.id) })
            }
            page.list.reload(rows, selecting: pets.firstIndex { $0.id == preferred }, dividerBefore: BundledPet.allCases.count)
        }
        updateButtons()
    }

    private func change(_ work: @escaping () throws -> (String?, Sheets)?) {
        isBusy = true
        automatic.libraryQueue.async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(.some(let (id, sheets))):
                    self.remember(id)
                    self.showSprites?(sheets)
                case .success(nil): self.refreshLibrary()
                case .failure(let error):
                    let alert = NSAlert(error: error)
                    alert.messageText = "Couldn’t change the companion"
                    alert.informativeText = error.localizedDescription
                    alert.presentInJack()
                }
            }
        }
    }

    @objc private func choose() {
        guard !isBusy, canChange(), let id = page?.selection?.id,
              id != (selectedID ?? BundledPet.appleJack.rawValue) else { return }
        change { [library] in (id, try library.load(id)) }
    }

    @objc private func importPet() {
        guard !isBusy, canChange(), let origin = page else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = ChatGPTPetCatalog.installed()
            DispatchQueue.main.async {
                guard self.page === origin, origin.window != nil else { self.isBusy = false; return }
                NSApp.activate(ignoringOtherApps: true)
                ChatGPTPetChooser(candidates).present { choice in
                    switch choice {
                    case .pet(let pet):
                        self.change { [library = self.library] in
                            let (saved, sheets) = try library.add(data: pet.data(), named: pet.name)
                            return (saved.id, sheets)
                        }
                    case .file: self.chooseSpriteFile()
                    case .cancel: self.isBusy = false
                    }
                }
            }
        }
    }

    private func chooseSpriteFile() {
        let panel = NSOpenPanel()
        panel.title = "Import ChatGPT Pet"
        panel.prompt = "Import"
        panel.message = "In ChatGPT, open your pet’s menu and choose Download sprite sheet. Select that PNG or WebP here."
        if #available(macOS 11, *) {
            panel.allowedContentTypes = [.png, .webP]
        } else {
            panel.allowedFileTypes = ["png", "webp"]
        }
        panel.canChooseDirectories = false
        let field = NSTextField(string: "")
        field.placeholderString = "Use filename"
        field.setAccessibilityLabel("Pet name")
        field.widthAnchor.constraint(equalToConstant: 205).isActive = true
        let row = NSStackView(views: [NSTextField(labelWithString: "Pet name"), field])
        row.frame.size = row.fittingSize
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { isBusy = false; return }
            let name = field.stringValue
            change { [library] in
                let (pet, sheets) = try library.add(from: url, named: name)
                return (pet.id, sheets)
            }
        }
    }

    @objc private func removeSelected() {
        guard !isBusy, canChange(), let pet = page?.selection, BundledPet(rawValue: pet.id) == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(pet.name) from Apple Jack?"
        let active = pet.id == selectedID
        alert.informativeText = active ? "Jack will use his original character. Your downloaded sprite sheet stays on your Mac." : "Your downloaded sprite sheet stays on your Mac."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        isBusy = true
        alert.presentInJack { [self] response in
            guard response == .alertSecondButtonReturn else { isBusy = false; return }
            change { [library] in
                let sheets = active ? try library.load(BundledPet.appleJack.rawValue) : nil
                try library.remove(pet)
                return sheets.map { (nil, $0) }
            }
        }
    }
}

private final class PetLibraryPage: NSView {
    let list = PetPreviewList(label: "Your companions")
    let use = NSButton(title: "Use Companion", target: nil, action: nil)
    let add = NSButton(title: "Import ChatGPT Pet…", target: nil, action: nil)
    let remove = NSButton(title: "Remove…", target: nil, action: nil)
    let auto = NSButton(checkboxWithTitle: "Automatically Import All ChatGPT Pets", target: nil, action: nil)
    let status = NSTextField(labelWithString: "")
    var choices: [ImportedPet] = []
    var selection: ImportedPet? { choices.indices.contains(list.selectedRow) ? choices[list.selectedRow] : nil }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 466, height: 328))
        list.setFrameOrigin(NSPoint(x: 24, y: 114))
        addSubview(list)
        let buttons = NSStackView(views: [add, remove, NSView(), use])
        buttons.frame = NSRect(x: 22, y: 76, width: 422, height: 30)
        addSubview(buttons)
        auto.frame = NSRect(x: 24, y: 44, width: 416, height: 24)
        addSubview(auto)
        status.frame = NSRect(x: 24, y: 4, width: 418, height: 36)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        addSubview(status)
    }
    required init?(coder: NSCoder) { fatalError() }
}
