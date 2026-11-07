import AppKit
import UniformTypeIdentifiers

/// The menu belongs to the thumbnail that was clicked, even if another drop
/// changes the selection or the order of the collection during menu tracking.
final class HeldItemMenu: NSMenu {
    private let id: UUID
    private let store: HoldThisStore
    private let reportError: (Error) -> Void
    private let showSharePicker: ([Any]) -> Void
    private var current: HeldItem? { store.items.first { $0.id == id } }

    init(item: HeldItem, store: HoldThisStore, reportError: @escaping (Error) -> Void,
         showSharePicker: @escaping ([Any]) -> Void) {
        self.id = item.id
        self.store = store
        self.reportError = reportError
        self.showSharePicker = showSharePicker
        super.init(title: "Hold This")
        autoenablesItems = false

        addItem(command(item.isPinned ? "Unpin" : "Pin", #selector(pinItem)))
        addItem(.separator())
        let url = location(of: item)
        let canOpen = item.kind == .text || url != nil
        let open = command("Open", #selector(openItem))
        open.isEnabled = canOpen
        addItem(open)
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = applicationsMenu(item: item, url: url)
        openWith.isEnabled = openWith.submenu?.items.isEmpty == false
        addItem(openWith)

        let share = command("Share", #selector(shareItem))
        share.image = JackIcon.image(named: "square.and.arrow.up", accessibilityDescription: nil)
        if #available(macOS 27.0, *) { share.preferredImageVisibility = .visible }
        share.isEnabled = canOpen
        addItem(share)

        addItem(.separator())
        let reveal = command("Reveal in Finder", #selector(revealItem))
        reveal.isEnabled = (item.kind == .image || item.kind == .file) && url != nil
        addItem(reveal)
    }

    required init(coder: NSCoder) { fatalError("HeldItemMenu is created for a held item") }

    private func command(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func location(of item: HeldItem) -> URL? {
        switch item.kind {
        case .file, .image:
            guard let url = store.fileURL(for: item), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        case .link: return URL(string: item.value)
        case .text: return nil
        }
    }

    private func applicationsMenu(item: HeldItem, url: URL?) -> NSMenu {
        let menu = NSMenu(title: "Open With")
        let workspace = NSWorkspace.shared
        let apps: [URL]
        let preferred: URL?
        if #available(macOS 12.0, *) {
            if let url {
                apps = workspace.urlsForApplications(toOpen: url)
                preferred = workspace.urlForApplication(toOpen: url)
            } else if item.kind == .text {
                apps = workspace.urlsForApplications(toOpen: UTType.plainText)
                preferred = workspace.urlForApplication(toOpen: UTType.plainText)
            } else { return menu }
        } else if let url {
            apps = LSCopyApplicationURLsForURL(url as CFURL, .all)?.takeRetainedValue() as? [URL] ?? []
            preferred = workspace.urlForApplication(toOpen: url)
        } else if item.kind == .text {
            let ids = LSCopyAllRoleHandlersForContentType("public.plain-text" as CFString, .all)?.takeRetainedValue() as? [String] ?? []
            apps = ids.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            let handler = LSCopyDefaultRoleHandlerForContentType("public.plain-text" as CFString, .all)?.takeRetainedValue() as String?
            preferred = handler.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        } else { return menu }

        var seen = Set<URL>()
        let candidates = ([preferred].compactMap { $0 } + apps).filter { seen.insert($0.standardizedFileURL).inserted }
        for app in candidates {
            let name = FileManager.default.displayName(atPath: app.path)
            let title = app == preferred ? name + " (default)" : name
            let choice = command(title, #selector(openWith(_:)))
            choice.representedObject = app
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            choice.image = icon
            choice.toolTip = app.path
            menu.addItem(choice)
        }
        return menu
    }

    @objc private func pinItem() {
        do { try store.togglePin(id) } catch { reportError(error) }
    }
    @objc private func openItem() { open(in: nil) }
    @objc private func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(in: app)
    }

    private func open(in app: URL?) {
        guard let item = current else { return }
        do {
            let url: URL
            if item.kind == .text {
                url = try item.temporaryTextDocument()
            } else if let resolved = location(of: item) { url = resolved }
            else { throw CocoaError(.fileNoSuchFile) }

            let configuration = NSWorkspace.OpenConfiguration()
            let completion: (NSRunningApplication?, Error?) -> Void = { [reportError] _, error in
                if let error { reportError(error) }
            }
            if let app {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration, completionHandler: completion)
            } else {
                NSWorkspace.shared.open(url, configuration: configuration, completionHandler: completion)
            }
        } catch { reportError(error) }
    }

    @objc private func revealItem() {
        guard let item = current else { return }
        guard let url = location(of: item), url.isFileURL else { reportError(CocoaError(.fileNoSuchFile)); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func shareItem() {
        guard let item = current else { return }
        if item.kind == .text { showSharePicker([item.value]) }
        else if let url = location(of: item) { showSharePicker([url]) }
        else { reportError(CocoaError(.fileNoSuchFile)) }
    }
}
