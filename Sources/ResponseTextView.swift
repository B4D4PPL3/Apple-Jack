import AppKit

struct ResponseLink {
    let range: NSRange
    let url: URL

    static func supported(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": return url.host?.isEmpty == false
        case "mailto": return URLComponents(url: url, resolvingAgainstBaseURL: false)?.path.isEmpty == false
        default: return false
        }
    }
    static func detect(in text: String) -> [ResponseLink] {
        let full = NSRange(text.startIndex..., in: text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var links = detector.matches(in: text, range: full).compactMap { match -> ResponseLink? in
            guard var url = match.url, supported(url) else { return nil }
            var range = match.range
            var spelling = (text as NSString).substring(with: range)
            // NSDataDetector may include the closing Markdown delimiter when
            // the URL itself contains parentheses, e.g. Wikipedia article URLs.
            while spelling.hasSuffix(")"), spelling.filter({ $0 == ")" }).count > spelling.filter({ $0 == "(" }).count {
                spelling.removeLast(); range.length -= 1
                if url.absoluteString.hasSuffix(")"), let trimmed = URL(string: String(url.absoluteString.dropLast())) { url = trimmed }
            }
            if url.scheme == "http", !spelling.lowercased().hasPrefix("http://") {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                url = components?.url ?? url
            }
            return ResponseLink(range: range, url: url)
        }
        // Keep the reply exactly as written, but make Markdown labels clickable
        // too. Only a user click opens a destination; response rendering never does.
        if let markdown = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]+)\]\("#) {
            let source = text as NSString
            let destinations = links
            for match in markdown.matches(in: text, range: full) {
                let start = NSMaxRange(match.range)
                if let destination = destinations.first(where: { $0.range.location == start }),
                   NSMaxRange(destination.range) < source.length,
                   source.substring(with: NSRange(location: NSMaxRange(destination.range), length: 1)) == ")" {
                    links.append(ResponseLink(range: match.range(at: 1), url: destination.url))
                }
            }
        }
        return links
    }
}

enum ResponseHoldContent {
    case link(URL), text(String)
    func write(to board: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        switch self {
        case .link(let url):
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
        case .text(let value): item.setString(value, forType: .string)
        }
        board.clearContents()
        return board.writeObjects([item])
    }
}

final class ResponseTextView: NSTextView, NSTextViewDelegate {
    private var ownedStorage: NSTextStorage?
    var usesMessageBubbleColors = false
    var holdContent: ((ResponseHoldContent) -> Void)?
    var openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var copyLink: (URL) -> Void = { _ = ResponseHoldContent.link($0).write(to: .general) }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let supplied: NSTextContainer
        let owned: NSTextStorage?
        if let container { supplied = container; owned = nil }
        else {
            let storage = NSTextStorage(), manager = NSLayoutManager()
            supplied = NSTextContainer(size: NSSize(width: max(1, frameRect.width), height: .greatestFiniteMagnitude))
            storage.addLayoutManager(manager); manager.addTextContainer(supplied)
            owned = storage
        }
        super.init(frame: frameRect, textContainer: supplied)
        ownedStorage = owned
        configureLinks()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); configureLinks() }
    private func configureLinks() {
        delegate = self
        isAutomaticLinkDetectionEnabled = false
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
    }
    override var string: String {
        get { super.string }
        set { super.string = newValue; refreshLinks() }
    }
    func refreshLinks() {
        guard let storage = textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.link, range: full)
        storage.removeAttribute(.toolTip, range: full)
        for link in ResponseLink.detect(in: storage.string) {
            var attributes: [NSAttributedString.Key: Any] = [.link: link.url, .toolTip: link.url.absoluteString]
            if usesMessageBubbleColors {
                let color = storage.attribute(.foregroundColor, at: link.range.location, effectiveRange: nil) as? NSColor
                attributes[.foregroundColor] = color == .white ? NSColor.white : NSColor.linkColor
            }
            storage.addAttributes(attributes, range: link.range)
        }
        storage.endEditing()
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), ResponseLink.supported(url) { openLink(url) }
        return true
    }
    func link(at point: NSPoint) -> URL? {
        guard let manager = layoutManager, let container = textContainer, manager.numberOfGlyphs > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: local, in: container)
        guard glyph < manager.numberOfGlyphs,
              manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < (string as NSString).length,
              let url = textStorage?.attribute(.link, at: index, effectiveRange: nil) as? URL,
              ResponseLink.supported(url) else { return nil }
        return url
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if let url = link(at: convert(event.locationInWindow, from: nil)) { return linkMenu(url) }
        return selectionMenu(base: super.menu(for: event) ?? NSMenu())
    }
    func selectionMenu(base menu: NSMenu) -> NSMenu {
        let selection = selectedRange()
        if selection.length > 0, NSMaxRange(selection) <= (string as NSString).length {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addHoldItem(to: menu, content: .text((string as NSString).substring(with: selection)))
        }
        return menu
    }
    func linkMenu(_ url: URL) -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Link", action: #selector(openSelectedLink), keyEquivalent: "")
        open.target = self; open.representedObject = url
        menu.addItem(open)
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copySelectedLink), keyEquivalent: "")
        copy.target = self; copy.representedObject = url
        menu.addItem(copy)
        menu.addItem(.separator())
        addHoldItem(to: menu, content: .link(url))
        return menu
    }
    private func addHoldItem(to menu: NSMenu, content: ResponseHoldContent) {
        let item = NSMenuItem(title: "Add to Hold This", action: #selector(holdSelection), keyEquivalent: "")
        item.target = self; item.representedObject = content
        item.isEnabled = holdContent != nil
        menu.addItem(item)
    }
    @objc private func openSelectedLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL, ResponseLink.supported(url) { openLink(url) }
    }
    @objc private func copySelectedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        copyLink(url)
    }
    @objc private func holdSelection(_ sender: NSMenuItem) {
        if let content = sender.representedObject as? ResponseHoldContent { holdContent?(content) }
    }
}
