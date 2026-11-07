import AppKit

enum ResponseBubbleSizing {
    static let minimumResponseHeight: CGFloat = 44

    // Use the same text engine and wrapping width as the response view, so
    // paragraphs, emoji, and long words are measured rather than estimated.
    static func textHeight(_ value: NSAttributedString, width: CGFloat,
                           inset: NSSize, lineFragmentPadding: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: value)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width - inset.width * 2),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = lineFragmentPadding
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let used = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        return ceil(used + inset.height * 2 + 2)
    }

    static func responseHeight(textHeight: CGFloat, chromeHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let limit = min(640, max(0, screenHeight - 40))
        return min(max(minimumResponseHeight, textHeight), max(minimumResponseHeight, limit - chromeHeight))
    }
}

final class ResponseBubbleLayout {
    private weak var bubble: SpeechBubble?
    private weak var stack: NSStackView?
    private weak var scroll: NSScrollView?
    private weak var text: NSTextView?
    private weak var anchor: NSWindow?
    private let height: NSLayoutConstraint
    private var observers: [NSObjectProtocol] = []
    private var scheduled = false
    private var resizing = false

    init(bubble: SpeechBubble, stack: NSStackView, scroll: NSScrollView, text: NSTextView, anchor: NSWindow) {
        self.bubble = bubble; self.stack = stack; self.scroll = scroll; self.text = text; self.anchor = anchor
        height = scroll.heightAnchor.constraint(equalToConstant: ResponseBubbleSizing.minimumResponseHeight)
        height.isActive = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSTextStorage.didProcessEditingNotification,
                                             object: text.textStorage, queue: .main) { [weak self] _ in self?.scheduleResize() })
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: anchor, queue: .main) { [weak self] _ in self?.scheduleResize() })
        }
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in self?.scheduleResize() })
        resizeNow()
    }

    func scheduleResize() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.resizeNow()
        }
    }

    func resizeNow() {
        guard !resizing, let bubble, let stack, let scroll, let text,
              let root = bubble.contentViewController?.view else { return }
        resizing = true
        defer { resizing = false }
        // Width stays unchanged; only the response viewport determines height.
        let width = bubble.contentSize.width - 48
        let visible = stack.arrangedSubviews.filter { !$0.isHidden }
        let chrome = 48 + CGFloat(max(0, visible.count - 1)) * stack.spacing
            + visible.filter { $0 !== scroll }.reduce(CGFloat(0)) { $0 + ceil($1.fittingSize.height) }
        let measured = ResponseBubbleSizing.textHeight(text.attributedString(), width: width,
            inset: text.textContainerInset, lineFragmentPadding: text.textContainer?.lineFragmentPadding ?? 5)
        let available = (anchor?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let responseHeight = ResponseBubbleSizing.responseHeight(textHeight: measured, chromeHeight: chrome, screenHeight: available)
        height.constant = responseHeight
        bubble.contentSize = NSSize(width: bubble.contentSize.width, height: ceil(chrome + responseHeight))
        root.layoutSubtreeIfNeeded()
        text.setFrameSize(NSSize(width: width, height: max(measured, responseHeight)))
        text.textContainer?.containerSize = NSSize(width: max(1, width - text.textContainerInset.width * 2),
                                                  height: .greatestFiniteMagnitude)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
