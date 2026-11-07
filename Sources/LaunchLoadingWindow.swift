import AppKit

private final class SlimeLoadingView: NSView {
    var progress = 0.0 { didSet { needsDisplay = true; setAccessibilityValue(Int(progress * 100)) } }
    var tick = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Apple Jack launching")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(100)
        setAccessibilityValue(0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        SlimeArtwork.draw(in: context, progress: progress, tick: tick)
    }
}

final class LaunchLoadingWindow {
    private let panel: NSPanel
    private let artwork: SlimeLoadingView
    private var timer: Timer?

    init() {
        let frame = NSRect(origin: .zero, size: SlimeArtwork.size)
        artwork = SlimeLoadingView(frame: frame)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.contentView = artwork
        panel.center()
    }
    func show() {
        panel.orderFrontRegardless()
        guard timer == nil else { return }
        let next = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let tick = reduced ? 0 : (self.artwork.tick + 1) % 120
            if tick != self.artwork.tick { self.artwork.tick = tick; self.artwork.needsDisplay = true }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
    func setKeepOnTop(_ enabled: Bool) { panel.level = enabled ? .floating : .normal }
    func setProgress(_ progress: Double) { artwork.progress = min(1, max(artwork.progress, progress)) }
    func close() { timer?.invalidate(); timer = nil; panel.orderOut(nil) }
    deinit { timer?.invalidate() }
}
