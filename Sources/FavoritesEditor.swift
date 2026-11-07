import AppKit
import UniformTypeIdentifiers

final class FavoritesEditor: NSObject {
    private let kind: JackFavorite.Kind
    private let original: JackFavorite?
    private let name = NSTextField(string: "")
    private let destination = NSTextField(string: "")
    init(kind: JackFavorite.Kind, original: JackFavorite? = nil) { self.kind = kind; self.original = original }

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = original == nil ? "Add \(kind.title) Favorite" : "Edit Favorite"
        switch kind {
        case .app: alert.informativeText = "Choose the application you want to open. Give it a short name for the Favorites menu."
        case .folder: alert.informativeText = "Choose the folder you want to open in Finder."
        case .website: alert.informativeText = "Enter a website address. Jack opens website favorites in Safari."
        case .shortcut: alert.informativeText = "Enter the exact name shown in Shortcuts. Jack runs it without opening the editor or sending your current message as input."
        }
        name.stringValue = original?.name ?? ""
        destination.stringValue = original?.destination ?? ""
        name.setAccessibilityLabel("Favorite name")
        destination.setAccessibilityLabel("Favorite destination")
        name.placeholderString = "Name shown in Favorites"
        destination.placeholderString = kind == .website ? "example.com" : kind == .shortcut ? "Exact shortcut name" : "Choose a location or enter its path"
        // NSAlert measures an accessory's frame before laying out its window.
        // An unconstrained frame on a stack view can collapse to zero here even
        // though its text fields still appear in the accessibility tree.
        let hasChooser = kind == .app || kind == .folder
        let height: CGFloat = hasChooser ? 156 : 114
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: height))
        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.frame = NSRect(x: 0, y: height - 20, width: 420, height: 20)
        name.frame = NSRect(x: 0, y: height - 52, width: 420, height: 26)
        let destinationLabel = NSTextField(labelWithString: kind == .shortcut ? "Shortcut name" : kind == .website ? "Website address" : "Location")
        destinationLabel.frame = NSRect(x: 0, y: height - 82, width: 420, height: 20)
        destination.frame = NSRect(x: 0, y: height - 114, width: 420, height: 26)
        for view in [nameLabel, name, destinationLabel, destination] {
            view.autoresizingMask = [.width]
            form.addSubview(view)
        }
        if hasChooser {
            let choose = NSButton(title: kind == .app ? "Choose App…" : "Choose Folder…", target: self, action: #selector(chooseLocation))
            choose.frame = NSRect(x: 0, y: 0, width: 150, height: 30)
            form.addSubview(choose)
        }
        alert.accessoryView = form
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        return alert
    }

    func run(save: (JackFavorite) throws -> Void) -> Bool {
        let alert = makeAlert()
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let label = (name.currentEditor()?.string ?? name.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
                let target = (destination.currentEditor()?.string ?? destination.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
                let entry: JackFavorite
                if var existing = original, target == existing.destination {
                    existing.name = label; entry = existing // Rename even when a drive is offline.
                } else {
                    entry = try JackFavorite.make(id: original?.id ?? UUID(), kind: kind, name: label, destination: target)
                }
                try save(entry); return true
            } catch { alert.informativeText = error.localizedDescription }
        }
        return false
    }
    @objc private func chooseLocation() {
        let picker = NSOpenPanel()
        picker.title = kind == .app ? "Choose an App" : "Choose a Folder"
        picker.prompt = "Choose"; picker.allowsMultipleSelection = false
        picker.canChooseDirectories = kind == .folder; picker.canChooseFiles = kind == .app
        picker.treatsFilePackagesAsDirectories = false
        if kind == .app {
            if #available(macOS 11, *) { picker.allowedContentTypes = [.application] }
            else { picker.allowedFileTypes = ["app"] }
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
        }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        destination.stringValue = url.path
        if name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name.stringValue = kind == .app ? (InstalledApp(url: url)?.name ?? url.deletingPathExtension().lastPathComponent) : url.lastPathComponent
        }
    }
}
