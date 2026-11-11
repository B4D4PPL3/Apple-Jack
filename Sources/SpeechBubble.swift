import AppKit

enum JackAppearance: String, CaseIterable {
    case system, light, dark
    static let preferenceKey = "interfaceAppearance"
    var title: String { rawValue.capitalized }
    static var selected: Self { Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system }
    var appearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

enum SpeechBubbleStyle: String, CaseIterable {
    case frosted, liquidGlass
    static let preferenceKey = "speechBubbleStyle"
    var title: String { self == .frosted ? "Frosted" : "Liquid Glass" }
    static var glassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    static var selected: Self {
        let saved = Self(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .frosted
        return saved == .liquidGlass && !glassAvailable ? .frosted : saved
    }
}

// Both grab surfaces update the same anchored panel in screen coordinates.
struct PetWindowDrag {
    private var start: (cursor: NSPoint, frame: NSRect)?
    private var lastSample = NSPoint.zero
    private(set) var moved = false

    mutating func begin(at cursor: NSPoint, window: NSWindow?) {
        start = window.map { (cursor, $0.frame) }
        lastSample = cursor
        moved = false
    }

    mutating func move(to cursor: NSPoint, window: NSWindow?, setDirection: (PetAnimation) -> Void) {
        guard let start, let window else { return }
        let dx = cursor.x - lastSample.x, dy = cursor.y - lastSample.y
        if abs(dx) >= 4 || abs(dy) >= 4 {
            moved = true
            lastSample = cursor
            if abs(dx) >= 4 { setDirection(dx > 0 ? .right : .left) }
        }
        guard moved else { return }
        let frame = start.frame.offsetBy(dx: cursor.x - start.cursor.x, dy: cursor.y - start.cursor.y)
        if let origin = Self.visibleOrigin(for: frame, displays: NSScreen.screens.map(\.visibleFrame)), origin != window.frame.origin {
            window.setFrameOrigin(origin)
        }
    }
    mutating func end(window: NSWindow?) {
        if moved, let window { window.saveFrame(usingName: window.frameAutosaveName) }
        self = Self()
    }
    static func visibleOrigin(for frame: NSRect, displays: [NSRect]) -> NSPoint? {
        // Choose from the proposed frame on each move, so a clamped edge on
        // the previous display never becomes the origin for the next event.
        let overlaps = displays.compactMap { display -> (NSRect, CGFloat)? in
            let overlap = frame.intersection(display)
            return overlap.isEmpty ? nil : (display, overlap.width * overlap.height)
        }
        guard let display = overlaps.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return NSPoint(x: min(max(display.minX, frame.minX), max(display.minX, display.maxX - frame.width)),
                       y: min(max(display.minY, frame.minY), max(display.minY, display.maxY - frame.height)))
    }

}

final class BubbleContentView: NSView {
    weak var petWindow: NSWindow?
    var dragSurfaces: [NSView] = []
    var dragPose: ((PetAnimation?) -> Void)?
    private var drag = PetWindowDrag()

    private func keepsScrollInteraction(_ view: NSView) -> Bool {
        if view is FavoritesListScrollView || view.enclosingScrollView is FavoritesListScrollView { return true }
        let setup = NSUserInterfaceItemIdentifier("AppleJackShortcutSetup")
        return view.identifier == setup || view.enclosingScrollView?.identifier == setup
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if keepsScrollInteraction(hit) { return hit }
        if hit is BubblePage || (hit.superview is BubblePage && hit is NSTextField) || hit is NSStackView || dragSurfaces.contains(where: { $0 === hit }) { return self }
        return hit
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        if let hit = hitTest(point), keepsScrollInteraction(hit) { return }
        (window as? GrabCursorPanel)?.grabBegan()
        drag.begin(at: NSEvent.mouseLocation, window: petWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        drag.move(to: NSEvent.mouseLocation, window: petWindow) { dragPose?($0) }
    }

    override func mouseUp(with event: NSEvent) { finishDrag() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow !== window { finishDrag() }
        super.viewWillMove(toWindow: newWindow)
    }
    private func finishDrag() {
        if drag.moved { dragPose?(nil) }
        (window as? GrabCursorPanel)?.grabEnded()
        drag.end(window: petWindow)
    }
}

// Both presentations share one content controller: switching material keeps
// the draft, answer, focus, recording and running request intact.
final class SpeechBubble: NSObject {
    var onBack: (() -> Bool)?
    weak var delegate: NSPopoverDelegate?
    var contentViewController: NSViewController?
    var contentSize = NSSize(width: 560, height: 280) {
        didSet {
            guard contentSize != oldValue else { return }
            contentViewController?.view.setFrameSize(contentSize)
            reposition()
            contentViewController?.view.layoutSubtreeIfNeeded()
        }
    }
    var frostAmount = GlassFrost.saved { didSet { refreshAppearance() } }
    var blurAmount = GlassBlur.saved { didSet { refreshAppearance() } }
    var animates = true
    var positioningRect = NSRect.zero { didSet { reposition() } }
    private var panel: BubblePanel?
    private var surface: BubbleSurface?
    private weak var anchorView: NSView?
    private var observers: [NSObjectProtocol] = []
    private var appearanceObserver: NSKeyValueObservation?
    var isShown: Bool { panel?.isVisible == true }

    override init() {
        super.init()
        appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            self?.refreshAppearance()
        }
    }
    func refreshAppearance() {
        // The window also owns the field editor used by an active draft.
        panel?.appearance = NSApp.effectiveAppearance
        contentViewController?.view.appearance = nil
        surface?.applyAppearance(NSApp.effectiveAppearance, frostAmount: frostAmount, blurAmount: blurAmount)
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        guard let controller = contentViewController, let parent = view.window else { return }
        anchorView = view
        positioningRect = rect
        if panel == nil {
            let style = SpeechBubbleStyle.selected
            let window = BubblePanel(contentRect: NSRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height + 12), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Apple Jack"
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = style == .frosted
            window.animationBehavior = animates && style == .frosted ? .utilityWindow : .none
            window.isMovableByWindowBackground = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.onEscape = { [weak self] in if self?.onBack?() != true { self?.performClose(nil) } }
            let surface = BubbleSurface(content: controller.view, size: contentSize, style: style)
            window.contentView = surface
            window.trackGrabAreas()
            self.surface = surface
            self.panel = window
        }
        guard let panel else { return }
        refreshAppearance()
        reposition()
        parent.addChildWindow(panel, ordered: .above)
        panel.level = parent.level
        panel.makeKeyAndOrderFront(nil)
        observeAnchor(parent)
        delegate?.popoverDidShow?(Notification(name: NSPopover.didShowNotification, object: self))
    }

    func refreshStyle() {
        guard isShown, let view = anchorView else { return }
        var responder = contentViewController?.view.window?.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor,
           let field = editor.delegate as? NSResponder { responder = field }
        dismissPanel()
        show(relativeTo: positioningRect, of: view)
        if let responder { contentViewController?.view.window?.makeFirstResponder(responder) }
    }

    func performClose(_ sender: Any?) {
        guard isShown else { return }
        dismissPanel()
        delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification, object: self))
    }
    private func dismissPanel() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        contentViewController?.view.removeFromSuperview()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
        }
        surface = nil
        panel = nil
    }
    private func observeAnchor(_ window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.reposition() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.reposition() })
    }
    private func reposition() {
        guard let panel, let surface, let view = anchorView, let parent = view.window,
              let screen = parent.screen ?? NSScreen.main else { return }
        let anchor = parent.convertToScreen(view.convert(positioningRect, to: nil))
        let placement = GlassBubblePlacement(anchor: anchor, contentSize: contentSize, visibleFrame: screen.visibleFrame)
        if panel.frame != placement.frame { panel.setFrame(placement.frame, display: true) }
        surface.arrange(size: contentSize, tailAtBottom: placement.tailAtBottom, tailX: placement.tailX)
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

// Keep the bubble visible near display edges and on secondary displays.
struct GlassBubblePlacement {
    let frame: NSRect
    let tailAtBottom: Bool
    let tailX: CGFloat
    init(anchor: NSRect, contentSize: NSSize, visibleFrame: NSRect) {
        let area = visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: contentSize.width, height: contentSize.height + 12)
        tailAtBottom = area.maxY - anchor.maxY >= size.height || anchor.minY - area.minY < size.height
        let desiredY = tailAtBottom ? anchor.maxY : anchor.minY - size.height
        let x = min(max(area.minX, anchor.midX - size.width / 2), max(area.minX, area.maxX - size.width))
        let y = min(max(area.minY, desiredY), max(area.minY, area.maxY - size.height))
        frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        tailX = min(max(anchor.midX - x, 32), size.width - 32)
    }
}

private final class BubblePanel: GrabCursorPanel {
    var onEscape: (() -> Void)?

    // Jack is a menu-bar app. Give the active field editor the standard Edit
    // commands using AppKit's key-equivalent matching and responder chain.
    private let editingCommands: NSMenu = {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }()

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor,
           editingCommands.performKeyEquivalent(with: event) { return true }
        if let shelf = firstResponder as? ShelfCollectionView, shelf.handleLinkReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil,
           let preview = BubbleNavigation.current?.visibleBody as? HeldItemPreview,
           preview.window === self, preview.handleKey(event) { return }
        super.sendEvent(event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// One continuous outline avoids a second window-sized border and a separate
// rectangular glass tail. The native material is clipped to this exact shape.
struct GlassBubbleOutline {
    static func path(size: NSSize, tailAtBottom: Bool, tailX: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let r: CGFloat = 24, h: CGFloat = 12, half: CGFloat = 12
        let bottom: CGFloat = tailAtBottom ? h : 0
        let top = bottom + size.height
        let right = size.width
        p.move(to: CGPoint(x: r, y: bottom))
        if tailAtBottom {
            p.addLine(to: CGPoint(x: tailX - half, y: bottom))
            p.addLine(to: CGPoint(x: tailX, y: 0))
            p.addLine(to: CGPoint(x: tailX + half, y: bottom))
        }
        p.addLine(to: CGPoint(x: right - r, y: bottom))
        p.addQuadCurve(to: CGPoint(x: right, y: bottom + r), control: CGPoint(x: right, y: bottom))
        p.addLine(to: CGPoint(x: right, y: top - r))
        p.addQuadCurve(to: CGPoint(x: right - r, y: top), control: CGPoint(x: right, y: top))
        if !tailAtBottom {
            p.addLine(to: CGPoint(x: tailX + half, y: top))
            p.addLine(to: CGPoint(x: tailX, y: top + h))
            p.addLine(to: CGPoint(x: tailX - half, y: top))
        }
        p.addLine(to: CGPoint(x: r, y: top))
        p.addQuadCurve(to: CGPoint(x: 0, y: top - r), control: CGPoint(x: 0, y: top))
        p.addLine(to: CGPoint(x: 0, y: bottom + r))
        p.addQuadCurve(to: CGPoint(x: r, y: bottom), control: CGPoint(x: 0, y: bottom))
        p.closeSubpath()
        return p
    }
}

private final class BubbleSurface: NSView {
    private let host = NSView()
    private let clip = CAShapeLayer()
    private let foregroundClip = CAShapeLayer()
    private let edge = CAShapeLayer()
    private let frost = CALayer()
    private let content: NSView
    private var frostedEffect: NSVisualEffectView?
    private var blurEffect: NSView?
    private let blurClip = CAShapeLayer()
    private var geometry: (size: NSSize, tailAtBottom: Bool, tailX: CGFloat)?

    init(content: NSView, size: NSSize, style: SpeechBubbleStyle) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height + 12))
        wantsLayer = true
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        let backdrop: NSView
        if style == .liquidGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 0
            glass.tintColor = nil
            glass.wantsLayer = true
            glass.layer?.mask = clip
            // Blend the native regular glass backdrop into clear glass. AppKit
            // owns its blur radius; this controls the extra blur's contribution.
            let blur = NSGlassEffectView(frame: host.bounds)
            blur.style = .regular
            blur.cornerRadius = 0
            blur.tintColor = nil
            blur.contentView = NSView(frame: host.bounds)
            blur.wantsLayer = true
            blur.layer?.mask = blurClip
            blur.autoresizingMask = [.width, .height]
            blur.isHidden = true
            blurEffect = blur
            let tint = NSView(frame: host.bounds)
            tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            tint.layer?.addSublayer(frost)
            host.addSubview(tint)
            // Foreground tint and controls stay above both backdrop effects.
            glass.contentView = NSView(frame: bounds)
            host.layer?.mask = foregroundClip
            backdrop = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.addSubview(host)
            frostedEffect = effect
            backdrop = effect
        }
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        host.frame = backdrop.bounds
        addSubview(backdrop)
        if let blur = blurEffect {
            addSubview(blur)
            addSubview(host)
        }
        content.appearance = nil
        content.autoresizingMask = []
        host.addSubview(content)
        edge.fillColor = nil
        edge.lineWidth = 1
        layer?.addSublayer(edge)
        setAccessibilityElement(false)
        arrange(size: size, tailAtBottom: true, tailX: size.width / 2)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard edge.path?.contains(local) == true else { return nil }
        if let hit = super.hitTest(point), hit === content || hit.isDescendant(of: content) { return hit }
        // The pointed tail and material margins drag the same anchor as the title.
        return content
    }

    func applyAppearance(_ appearance: NSAppearance, frostAmount: Double, blurAmount: Double) {
        self.appearance = appearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        edge.strokeColor = (dark ? NSColor.white.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.18)).cgColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frost.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(GlassFrost.tintAlpha(frostAmount)).cgColor
        let blur = GlassBlur.normalized(blurAmount)
        blurEffect?.alphaValue = CGFloat(blur)
        blurEffect?.isHidden = blur == 0
        CATransaction.commit()
    }
    func arrange(size: NSSize, tailAtBottom: Bool, tailX: CGFloat) {
        if let geometry, geometry == (size, tailAtBottom, tailX) { return }
        geometry = (size, tailAtBottom, tailX)
        let outline = GlassBubbleOutline.path(size: size, tailAtBottom: tailAtBottom, tailX: tailX)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        setFrameSize(NSSize(width: size.width, height: size.height + 12))
        clip.frame = bounds; clip.path = outline
        foregroundClip.frame = bounds; foregroundClip.path = outline
        blurClip.frame = bounds; blurClip.path = outline
        edge.frame = bounds; edge.path = outline
        frost.frame = bounds
        if frostedEffect != nil {
            let mask = NSImage(size: bounds.size, flipped: false) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.addPath(outline)
                context.setFillColor(NSColor.white.cgColor)
                context.fillPath()
                return true
            }
            frostedEffect?.maskImage = mask
        }
        content.frame = NSRect(x: 0, y: tailAtBottom ? 12 : 0, width: size.width, height: size.height)
        CATransaction.commit()
    }
}
