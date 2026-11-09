import AppKit
import WebKit

/// Each page uses the same anchored window as the chat. The chat view stays alive
/// while away, so its controls, draft, response and in-flight request keep their state.
final class BubbleNavigation: NSObject, WKNavigationDelegate {
    static weak var current: BubbleNavigation?
    private let bubble: SpeechBubble
    private let root: BubbleContentView
    private let home: NSView
    private let reveal: () -> Void
    private let restoreChat: () -> Void
    private var pages: [BubblePage] = []
    private var homeSize = NSSize.zero
    var isEditing: Bool { pages.contains { $0.cancelForm != nil } }
    var visibleBody: NSView? { pages.last?.body }
    var isReading: Bool { !pages.isEmpty }
    private weak var initialFocus: NSResponder?

    init(bubble: SpeechBubble, root: BubbleContentView, home: NSView,
         reveal: @escaping () -> Void, restoreChat: @escaping () -> Void) {
        self.bubble = bubble; self.root = root; self.home = home
        self.reveal = reveal; self.restoreChat = restoreChat
        super.init()
    }

    @discardableResult
    func show(_ title: String, body: NSView, size: NSSize, minimum: NSSize? = nil, returnFocus: NSView? = nil,
              leaving: (() -> Void)? = nil) -> BubblePage {
        if !bubble.isShown { reveal() }
        if pages.isEmpty {
            homeSize = bubble.contentSize
            initialFocus = returnFocus ?? root.window?.firstResponder
            if let editor = initialFocus as? NSTextView, editor.isFieldEditor { initialFocus = editor.delegate as? NSResponder }
            root.window?.makeFirstResponder(nil)
            home.removeFromSuperview()
        } else { pages.last?.removeFromSuperview() }
        let page = BubblePage(title: title, body: body, size: size, minimum: minimum ?? size)
        page.leaving = leaving
        page.back.target = self; page.back.action = #selector(back)
        pages.append(page); display(page)
        return page
    }
    private func fit(_ page: BubblePage) {
        let area = (root.petWindow?.screen ?? NSScreen.main)?.visibleFrame.size ?? page.ideal
        let size = NSSize(width: min(page.ideal.width, max(200, area.width - 20)),
                          height: min(page.ideal.height + BubblePage.headerHeight, max(150, area.height - 36)))
        bubble.contentSize = size
        page.frame = CGRect(origin: .zero, size: size)
        page.autoresizingMask = [.width, .height]
        page.layoutSubtreeIfNeeded()
    }
    private func display(_ page: BubblePage) {
        fit(page)
        root.addSubview(page)
        root.window?.makeFirstResponder(page.back)
    }

    @objc func back() {
        guard let page = pages.last else { return }
        if let cancel = page.cancelForm { cancel(); return }
        pop()
    }
    private func pop() {
        guard let page = pages.popLast() else { return }
        root.window?.makeFirstResponder(nil)
        page.removeFromSuperview()
        page.body.removeFromSuperview()
        page.leaving?()
        if let previous = pages.last { display(previous) }
        else {
            bubble.contentSize = homeSize
            home.frame = root.bounds; root.addSubview(home)
            restoreChat()
            if let focus = initialFocus as? NSView, focus.window === root.window { root.window?.makeFirstResponder(focus) }
            initialFocus = nil
        }
    }
    func reset() {
        while let page = pages.last {
            if let cancel = page.cancelForm { cancel() }
            if pages.last === page { pop() }
        }
    }
    func close(_ panel: NSWindow) {
        if pages.last?.source === panel { back() }
    }
    func show(_ panel: NSWindow, title: String, onLeave: (() -> Void)? = nil) {
        if let index = pages.firstIndex(where: { $0.source === panel }) {
            while pages.count > index + 1 { if pages.last?.cancelForm != nil { return }; pop() }
            return
        }
        guard let body = panel.contentView else { return }
        let resizable = panel.styleMask.contains(.resizable)
        let key = "Bubble Page Size." + panel.title
        var size = body.frame.size
        if resizable, let saved = UserDefaults.standard.string(forKey: key) {
            let value = NSSizeFromString(saved)
            if value.width >= panel.contentMinSize.width && value.height >= panel.contentMinSize.height { size = value }
        }
        panel.contentView = nil
        let page = show(title, body: body, size: size, minimum: panel.contentMinSize) {
            body.frame = NSRect(origin: .zero, size: size)
            panel.contentView = body
            onLeave?()
        }
        page.source = panel
        if resizable {
            page.enableResizing { [weak self, weak page] proposed in
                guard let self, let page, self.pages.last === page else { return }
                let area = self.root.petWindow?.screen?.visibleFrame.size ?? page.ideal
                page.ideal = NSSize(width: min(area.width - 20, max(panel.contentMinSize.width, proposed.width)),
                                    height: min(area.height - 36 - BubblePage.headerHeight, max(panel.contentMinSize.height, proposed.height)))
                UserDefaults.standard.set(NSStringFromSize(page.ideal), forKey: key)
                self.fit(page)
            }
        }
    }
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if !bubble.isShown { reveal() }
        guard let window = root.window else { completion(alert.runModal()); return }
        let focus = alert.window.initialFirstResponder
        let form = BubbleForm(alert)
        let page = show(alert.messageText, body: form, size: form.frame.size)
        // Return from the menu action before handling clicks in the new page.
        // The existing bubble continues to receive its normal AppKit events.
        form.finish = { [weak self, weak page, weak form] response in
            guard let self, let page, let form, self.pages.last === page else { return }
            form.finish = nil
            page.cancelForm = nil
            window.makeFirstResponder(nil)
            self.pop()
            form.restoreAccessory()
            completion(response)
        }
        page.cancelForm = { [weak form] in form?.finish?(.cancel) }
        if let focus, focus.window === window { window.makeFirstResponder(focus) }
    }

    func guide(_ url: URL) {
        let view = WKWebView()
        view.navigationDelegate = self
        view.setAccessibilityLabel("Apple Jack Setup Guide")
        show("Setup Guide", body: view, size: NSSize(width: 660,height: 465), minimum: NSSize(width: 300,height: 140))
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel)
            NSWorkspace.shared.open(url)
        } else { decisionHandler(.allow) }
    }

    func about() {
        let body = NSView()
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let name = NSTextField(labelWithString: "Apple Jack")
        name.font = .boldSystemFont(ofSize: 24)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = NSTextField(labelWithString: "Version " + (info["CFBundleShortVersionString"] as? String ?? "") + "  ·  Build " + (info["CFBundleVersion"] as? String ?? ""))
        version.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [name,version]); labels.orientation = .vertical; labels.alignment = .leading
        let brand = NSStackView(views: [icon,labels]); brand.spacing = 12
        let credit = NSTextField(labelWithString: "Created by B4D4PPL3")
        let thanks = NSTextField(wrappingLabelWithString: "Thank you for using Apple Jack and giving him a home on your Mac.")
        let links = NSStackView(views: [link("GitHub Project", #selector(repository)),link("GitHub Profile", #selector(profile)),link("mikefonz.com", #selector(website))])
        let stack = NSStackView(views: [brand,credit,thanks,links])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: body.topAnchor,constant: 10),
            stack.leadingAnchor.constraint(equalTo: body.leadingAnchor,constant: 22),stack.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor,constant: -22)])
        show("About Apple Jack", body: body, size: NSSize(width: 500,height: 205))
    }
    private func link(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title,target: self,action: action) }
    @objc private func repository() { NSWorkspace.shared.open(URL(string: "https://github.com/B4D4PPL3/Apple-Jack")!) }
    @objc private func profile() { NSWorkspace.shared.open(URL(string: "https://github.com/B4D4PPL3")!) }
    @objc private func website() { NSWorkspace.shared.open(URL(string: "https://mikefonz.com")!) }
}

extension NSAlert {
    func presentInJack(_ completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        if let nav = BubbleNavigation.current { nav.present(self, completion: completion) }
        else { completion(runModal()) }
    }

    func editInJack(validate: @escaping () -> Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        presentInJack { response in
            guard response == .alertFirstButtonReturn else { completion(false); return }
            if validate() { completion(true) }
            else { self.editInJack(validate: validate, completion: completion) }
        }
    }
}

private final class TopAlignedCanvas: NSView { override var isFlipped: Bool { true } }
final class BubblePage: NSView {
    static let headerHeight: CGFloat = 56
    var ideal: NSSize
    let body: NSView
    let back = NSButton(title: "‹  Back", target: nil, action: nil)
    private let title: NSTextField
    private let scroll = NSScrollView()
    private let canvas = TopAlignedCanvas()
    private var grip: PageResizeGrip?
    private let minimum: NSSize
    weak var source: NSWindow?
    var cancelForm: (() -> Void)?
    var leaving: (() -> Void)?
    init(title: String, body: NSView, size: NSSize, minimum: NSSize) {
        self.body = body; self.ideal = size; self.minimum = minimum
        self.title = NSTextField(labelWithString: title)
        super.init(frame: NSRect(origin: .zero, size: size))
        back.setAccessibilityLabel("Back"); back.toolTip = "Back"
        self.title.font = .boldSystemFont(ofSize: 19)
        addSubview(back); addSubview(self.title); addSubview(scroll)
        scroll.drawsBackground = false; scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.documentView = canvas; canvas.addSubview(body)
    }
    required init?(coder: NSCoder) { fatalError() }
    func enableResizing(_ resize: @escaping (NSSize) -> Void) {
        let grip = PageResizeGrip()
        grip.initialSize = { [weak self] in self?.ideal ?? .zero }
        grip.resize = resize
        grip.toolTip = "Drag to resize"
        grip.setAccessibilityLabel("Drag to resize this page")
        addSubview(grip)
        self.grip = grip
        needsLayout = true
    }
    override func layout() {
        super.layout()
        back.frame = NSRect(x: 16,y: bounds.height - 44,width: 74,height: 28)
        title.frame = NSRect(x: 102,y: bounds.height - 43,width: max(30,bounds.width - 124),height: 27)
        scroll.frame = NSRect(x: 0,y: 0,width: bounds.width,height: max(1,bounds.height - Self.headerHeight))
        grip?.frame = NSRect(x: bounds.width - 27, y: 3, width: 18, height: 15)
        let visible = scroll.contentSize
        canvas.setFrameSize(NSSize(width: max(minimum.width,visible.width),height: max(minimum.height,visible.height)))
        body.frame = canvas.bounds
    }
}

private final class PageResizeGrip: NSView {
    var initialSize: (() -> NSSize)?
    var resize: ((NSSize) -> Void)?
    private var start = NSPoint.zero
    private var size = NSSize.zero
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        size = initialSize?() ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        let cursor = NSEvent.mouseLocation
        resize?(NSSize(width: size.width + cursor.x - start.x, height: size.height + start.y - cursor.y))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let marks = NSBezierPath()
        for offset in [3, 7, 11] {
            marks.move(to: CGPoint(x: 15 - offset, y: 2))
            marks.line(to: CGPoint(x: 15, y: 2 + offset))
        }
        marks.stroke()
    }
}

private final class BubbleForm: NSView {
    var finish: ((NSApplication.ModalResponse) -> Void)?
    private let alert: NSAlert
    private let accessory: NSView?
    private var observations: [NSKeyValueObservation] = []
    init(_ alert: NSAlert) {
        self.alert = alert
        accessory = alert.accessoryView
        let dimensions = accessory?.frame.size ?? .zero
        let buttons = alert.buttons
        let actions = buttons.isEmpty ? [NSButton(title: "OK",target: nil,action: nil)] : buttons
        let widths = actions.map { max(72,ceil($0.fittingSize.width) + 10) }
        let rowWidth = widths.reduce(0,+) + CGFloat(max(0, actions.count - 1)) * 8
        let width = max(490, dimensions.width + 48, rowWidth + 48)
        let note = NSTextField(wrappingLabelWithString: alert.informativeText)
        let noteHeight = ceil(note.cell?.cellSize(forBounds: NSRect(x: 0,y: 0,width: width - 48,height: 1200)).height ?? 36)
        let height = 22 + noteHeight + 12 + dimensions.height + 52
        super.init(frame: NSRect(x: 0,y: 0,width: width,height: height))
        note.frame = NSRect(x: 24,y: height - 8 - noteHeight,width: width - 48,height: noteHeight)
        addSubview(note)
        if let accessory {
            accessory.removeFromSuperview()
            accessory.frame = CGRect(origin: CGPoint(x: 24,y: 52), size: dimensions)
            addSubview(accessory)
        }
        var right = width - 24
        for (index, original) in actions.enumerated() {
            let button = NSButton(title: original.title,target: self,action: #selector(choose(_:)))
            button.tag = index
            button.keyEquivalent = original.keyEquivalent
            if button.keyEquivalent.isEmpty && index == 0 { button.keyEquivalent = "\r" }
            button.isEnabled = original.isEnabled
            observations.append(original.observe(\.isEnabled) { [weak button] control,_ in button?.isEnabled = control.isEnabled })
            right -= widths[index]
            button.frame = NSRect(x: right,y: 12,width: widths[index],height: 28)
            addSubview(button); right -= 8
        }
    }
    func restoreAccessory() {
        if let accessory { accessory.removeFromSuperview(); alert.accessoryView = accessory }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func choose(_ sender: NSButton) {
        let response = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + sender.tag)
        finish?(response)
    }
}
