import AppKit

// The transcript keeps its scroll position while new replies arrive.
final class ConversationWindow: NSObject {
    private var panel: NSPanel?
    private let scroll = NSScrollView()
    private let storage = NSTextStorage()
    private let bubbles = BubbleTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private let transcript: NSTextView
    private var turnStarts: [UUID: Int] = [:]
    private var firstTurnID: UUID?
    private let status = NSTextField(wrappingLabelWithString: "")
    private let remember = NSButton(checkboxWithTitle: "Remember this conversation", target: nil, action: nil)
    private let assistantButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let newButton = NSButton(title: "New Conversation", target: nil, action: nil)
    private let memory: ConversationMemory
    var newConversation: (() -> Void)?
    var toggleMemory: (() -> Void)?
    var isBusy: (() -> Bool)?
    var assistantTitle: (() -> String)?
    var configureAssistantMenu: ((NSMenu) -> Void)?

    init(memory: ConversationMemory) {
        self.memory = memory
        let layout = BubbleLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(bubbles)
        bubbles.lineFragmentPadding = 0
        transcript = NSTextView(frame: .zero, textContainer: bubbles)
        super.init()
    }
    func show() {
        let opening = scroll.window?.isVisible != true
        if panel == nil { build() }
        refreshAppearance()
        panel?.level = UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true ? .floating : .normal
        refreshControls()
        NSApp.activate(ignoringOtherApps: true)
        if let nav = BubbleNavigation.current, let panel { nav.show(panel, title: "Conversation History") }
        else { panel?.makeKeyAndOrderFront(nil) }
        if opening { render(followLatest: true) }
    }
    func refreshAppearance() { panel?.appearance = NSApp.appearance }
    func setLevel(_ level: NSWindow.Level) { panel?.level = level }
    func refresh() {
        guard panel != nil else { return }
        refreshControls()
        render()
    }
    func refreshControls() {
        guard panel != nil else { return }
        remember.state = memory.enabled ? .on : .off
        let busy = isBusy?() ?? false
        remember.isEnabled = !busy; assistantButton.isEnabled = !busy; newButton.isEnabled = !busy
        let count = memory.turns.count
        status.stringValue = memory.enabled
            ? "\(assistantTitle?() ?? "Apple Jack") · \(count) \(count == 1 ? "reply" : "replies") · This session only\nRecent messages are included with your next AI question. New Conversation, switching assistants or shortcuts, turning memory off, and quitting clear this history."
            : "Memory is off. Questions are sent individually and no conversation history is kept."
    }
    private func render(followLatest: Bool = false) {
        scroll.superview?.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        let wasAtBottom = clip.documentRect.maxY - clip.bounds.maxY <= 2
        let follow = followLatest || wasAtBottom
        // When the history limit drops old turns, keep the retained text at
        // the same height in the reader's viewport.
        let first = memory.turns.first?.id
        var previousFirstY: CGFloat?
        if !follow, first != firstTurnID, let first, let index = turnStarts[first] {
            previousFirstY = lineY(at: index)
        }
        firstTurnID = first
        turnStarts.removeAll(keepingCapacity: true)
        let text = NSMutableAttributedString(string: "")
        var messages: [BubbleMessage] = []
        let font = NSFont.systemFont(ofSize: 14)
        func appendNotice(_ value: String) {
            text.append(NSAttributedString(string: value, attributes: [
                .font: font, .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        func appendMessage(_ value: String, outgoing: Bool) {
            let caption = NSMutableParagraphStyle()
            caption.alignment = outgoing ? .right : .left
            caption.paragraphSpacingBefore = text.length == 0 ? 0 : 16
            caption.paragraphSpacing = 9
            text.append(NSAttributedString(string: outgoing ? "You\n" : "Apple Jack\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: caption
            ]))
            let start = text.length
            let body = NSAttributedString(string: value + "\n", attributes: [
                .font: font, .foregroundColor: outgoing ? NSColor.white : NSColor.labelColor
            ])
            text.append(body)
            let naturalWidth = (value as NSString).boundingRect(
                with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]
            ).width
            messages.append(BubbleMessage(range: NSRange(location: start, length: body.length),
                                          outgoing: outgoing, naturalWidth: ceil(naturalWidth) + 1))
        }
        if memory.turns.isEmpty {
            appendNotice(memory.enabled ? "Your conversation will appear here after Jack replies.\n\nTry asking a question, then a follow-up like “Make it shorter.”" : "Turn on Remember this conversation to let Jack understand follow-up questions.")
        } else {
            if memory.omittedTurns > 0 { appendNotice("Showing the latest \(ConversationMemory.historyLimit) replies. Older exchanges have been cleared.\n") }
            for turn in memory.turns {
                turnStarts[turn.id] = text.length
                appendMessage(turn.user, outgoing: true)
                appendMessage(turn.assistant, outgoing: false)
            }
        }
        bubbles.messages = messages
        storage.setAttributedString(text)
        transcript.needsDisplay = true
        if let container = transcript.textContainer { transcript.layoutManager?.ensureLayout(for: container) }
        if follow {
            origin.y = clip.documentRect.maxY - clip.bounds.height
        } else if let previousFirstY, let first, let index = turnStarts[first], let y = lineY(at: index) {
            origin.y += y - previousFirstY
        }
        let desired = NSRect(origin: origin, size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(desired).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func lineY(at character: Int) -> CGFloat? {
        guard let layout = transcript.layoutManager else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: character)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }
    @objc private func startNew() { newConversation?() }
    @objc private func toggle() { toggleMemory?() }
    private func build() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel = window; window.title = "Apple Jack Conversation"
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        window.center()
        let content = NSView(); window.contentView = content
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        remember.target = self; remember.action = #selector(toggle)
        newButton.target = self; newButton.action = #selector(startNew)
        assistantButton.addItem(withTitle: "AI Assistant")
        assistantButton.setAccessibilityLabel("AI Assistant")
        assistantButton.toolTip = "Choose Jack’s AI assistant. Switching assistants starts a new conversation."
        (assistantButton.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        if let menu = assistantButton.menu { configureAssistantMenu?(menu) }
        let header = NSStackView()
        header.spacing = 8
        header.addView(remember, in: .leading)
        header.addView(assistantButton, in: .trailing)
        header.addView(newButton, in: .trailing)
        window.contentMinSize = NSSize(width: max(460, ceil(header.fittingSize.width) + 32), height: 280)
        stack.addArrangedSubview(header); header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder; scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        transcript.isEditable = false; transcript.isSelectable = true
        transcript.drawsBackground = true; transcript.backgroundColor = .textBackgroundColor
        transcript.isVerticallyResizable = true; transcript.isHorizontallyResizable = false
        transcript.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        transcript.autoresizingMask = [.width]; transcript.textContainer?.widthTracksTextView = true
        transcript.textContainerInset = NSSize(width: 16, height: 14)
        transcript.setAccessibilityLabel("Conversation messages")
        scroll.documentView = transcript
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}

// Keep one selectable, accessible transcript. The container sets each message's
// wrapping width, and the layout manager paints behind the native text selection.
private struct BubbleMessage {
    let range: NSRange
    let outgoing: Bool
    let naturalWidth: CGFloat

    static let padding: CGFloat = 12
    func textColumn(in width: CGFloat) -> CGRect {
        let available = max(1, floor(width * 0.78) - 2 * Self.padding)
        let body = min(available, max(8, naturalWidth))
        return CGRect(x: outgoing ? width - Self.padding - body : Self.padding,
                      y: 0, width: body, height: 0)
    }
}

private final class BubbleTextContainer: NSTextContainer {
    var messages: [BubbleMessage] = []
    override var isSimpleRectangularTextContainer: Bool { false }

    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int,
                                   writingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        let line = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex,
                                           writingDirection: writingDirection, remaining: remainingRect)
        guard let message = messages.first(where: { NSLocationInRange(characterIndex, $0.range) }) else { return line }
        let column = message.textColumn(in: size.width)
        remainingRect?.pointee = .zero
        return line.intersection(CGRect(x: column.minX, y: line.minY, width: column.width, height: line.height))
    }
}

private final class BubbleLayoutManager: NSLayoutManager {
    private static let incoming = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(srgbRed: dark ? 0.20 : 0.91, green: dark ? 0.20 : 0.91,
                       blue: dark ? 0.22 : 0.93, alpha: 1)
    }
    private static let outgoing = NSColor(srgbRed: 0.035, green: 0.37, blue: 0.79, alpha: 1)

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let container = textContainers.first as? BubbleTextContainer {
            let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            for message in container.messages where NSIntersectionRange(visible, message.range).length > 0 {
                let first = glyphIndexForCharacter(at: message.range.location)
                let last = glyphIndexForCharacter(at: NSMaxRange(message.range) - 1)
                let top = lineFragmentUsedRect(forGlyphAt: first, effectiveRange: nil).minY
                let bottom = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil).maxY
                let column = message.textColumn(in: container.size.width)
                let rect = CGRect(x: origin.x + column.minX - BubbleMessage.padding, y: origin.y + top - 6,
                                  width: column.width + 2 * BubbleMessage.padding, height: bottom - top + 12)
                (message.outgoing ? Self.outgoing : Self.incoming).setFill()
                let shape = NSBezierPath(roundedRect: rect, xRadius: 15, yRadius: 15)
                // The transcript is flipped. Mirror the small curved tail at the lower corner.
                func tailPoint(_ inward: CGFloat, _ up: CGFloat) -> NSPoint {
                    NSPoint(x: message.outgoing ? rect.maxX - inward : rect.minX + inward, y: rect.maxY - up)
                }
                let tail = NSBezierPath()
                tail.move(to: tailPoint(1, 14))
                tail.curve(to: tailPoint(-4, 0.5), controlPoint1: tailPoint(1, 7), controlPoint2: tailPoint(0, 3))
                tail.curve(to: tailPoint(12, 6), controlPoint1: tailPoint(2, 0), controlPoint2: tailPoint(8, 2))
                tail.close()
                shape.fill()
                tail.fill()
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
