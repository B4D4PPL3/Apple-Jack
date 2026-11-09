import AppKit

final class ChatGPTPetChooser: NSObject {
    enum Choice { case pet(ChatGPTPetCandidate), file, cancel }
    private var candidates: [ChatGPTPetCandidate]
    private let status = NSTextField(labelWithString: "")
    private var userSelected = false
    private let pets = PetPreviewList(label: "Available ChatGPT pets")
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
        pets.setFrameOrigin(NSPoint(x: 0, y: 42))
        content.addSubview(pets)
        status.frame = NSRect(x: 2, y: 0, width: 410, height: 38)
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        content.addSubview(status)
        dialog.accessoryView = content
        pets.onSelect = { [weak self] in self?.userSelected = true }
        reload(selecting: 0)
        dialog.window.initialFirstResponder = pets.table
    }

    func present(completion: @escaping (Choice) -> Void) {
        status.stringValue = "Checking your ChatGPT account for custom pets…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let cloud = Result { try ChatGPTAccountPets.list() }
            RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in self?.apply(cloud) }
        }
        dialog.presentInJack { [self] response in
            pets.cancelPreview()
            switch response {
            case .alertFirstButtonReturn where candidates.indices.contains(pets.selectedRow): completion(.pet(candidates[pets.selectedRow]))
            case .alertSecondButtonReturn: completion(.file)
            default: completion(.cancel)
            }
        }
    }

    private func apply(_ cloud: Result<[ChatGPTPetCandidate], Error>) {
        switch cloud {
        case .failure:
            status.stringValue = "Account pets are unavailable. Check your ChatGPT sign-in and connection, or choose a file."
        case .success(let accountPets):
            let merged = ChatGPTPetCatalog.merged(local: candidates, account: accountPets)
            status.stringValue = merged.isEmpty ? "No pets found. Choose a downloaded sprite sheet to import." : ""
            guard merged.count > candidates.count else { return }
            let previousID = candidates.indices.contains(pets.selectedRow) ? candidates[pets.selectedRow].id : nil
            let row = userSelected ? merged.firstIndex(where: { $0.id == previousID }) ?? 0 : 0
            candidates = merged
            reload(selecting: row)
            dialog.buttons[0].isEnabled = true
        }
    }

    private func reload(selecting row: Int) {
        pets.reload(candidates.map { PetPreviewList.Row(name: $0.name, source: $0.sourceName, preview: $0.preview) }, selecting: row)
    }
}
