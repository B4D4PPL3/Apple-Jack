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
        controller.changed = { [weak self] in self?.refreshMenus() }
        return controller
    }()
    func startAutomaticImports() { automatic.start() }

    private let selectionKey = "selectedImportedPet"
    private let menus = NSHashTable<NSMenu>.weakObjects()
    private lazy var pets = library.entries()
    private(set) var isBusy = false
    var canChange: () -> Bool = { false }
    var showSprites: ((Sheets) -> Void)?
    var selectedID: String? {
        let id = UserDefaults.standard.string(forKey: selectionKey)
        return id == BundledPet.appleJack.rawValue ? nil : id
    }

    func menuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Pets", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: parent.title)
        menus.add(menu)
        populate(menu)
        parent.submenu = menu
        return parent
    }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, id: String? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = id
            if action == #selector(choose(_:)) { item.state = selectedID == id ? .on : .off }
        }
        for pet in BundledPet.allCases {
            add(pet.name, #selector(choose(_:)), id: pet == .appleJack ? nil : pet.rawValue)
        }
        if !pets.isEmpty {
            menu.addItem(.separator())
            for pet in pets { add(pet.name, #selector(choose(_:)), id: pet.id) }
        }
        menu.addItem(.separator())
        add("Import ChatGPT Pet…", #selector(importPet))
        let auto = menu.addItem(withTitle: "Automatically Import All ChatGPT Pets", action: #selector(toggleAutoImport), keyEquivalent: "")
        auto.target = self
        auto.state = automatic.isEnabled ? .on : .off
        if let text = automatic.status {
            let status = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        if pets.contains(where: { $0.id == selectedID }) { add("Remove Selected Pet…", #selector(removeSelected)) }
    }

    @objc private func toggleAutoImport() { automatic.toggle() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !isBusy && canChange() }

    func remember(_ id: String?) {
        if let id, id != BundledPet.appleJack.rawValue { UserDefaults.standard.set(id, forKey: selectionKey) }
        else { UserDefaults.standard.removeObject(forKey: selectionKey) }
        refreshMenus()
    }

    private func refreshMenus() {
        pets = library.entries()
        for menu in menus.allObjects { populate(menu) }
    }

    private func change(_ work: @escaping () throws -> (String?, Sheets)) {
        isBusy = true
        automatic.libraryQueue.async {
            let result = Result { try work() }
            DispatchQueue.main.async {
                self.isBusy = false
                switch result {
                case .success(let (id, sheets)):
                    self.remember(id)
                    self.showSprites?(sheets)
                case .failure(let error):
                    let alert = NSAlert(error: error)
                    alert.messageText = "Couldn’t change the pet"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc private func choose(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        guard !isBusy, canChange(), id != selectedID else { return }
        change { [library] in
            return (id, try library.load(id ?? BundledPet.appleJack.rawValue))
        }
    }

    @objc private func importPet() {
        guard !isBusy, canChange() else { return }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = ChatGPTPetCatalog.installed()
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                switch ChatGPTPetChooser(candidates).run() {
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

    private func chooseSpriteFile() {
        let panel = NSOpenPanel()
        panel.title = "Import ChatGPT Pet"
        panel.prompt = "Import"
        panel.message = "In ChatGPT, open your pet’s menu and choose Download sprite sheet. Select that PNG or WebP here."
        panel.allowedContentTypes = [.png, .webP]
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
        guard !isBusy, canChange(), let pet = pets.first(where: { $0.id == selectedID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(pet.name) from Apple Jack?"
        alert.informativeText = "Jack will use his original character. Your downloaded sprite sheet stays on your Mac."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        isBusy = true
        guard alert.runModal() == .alertSecondButtonReturn else { isBusy = false; return }
        change { [library] in
            let sheets = try library.load(BundledPet.appleJack.rawValue)
            try library.remove(pet)
            return (nil, sheets)
        }
    }
}
