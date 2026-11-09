import AppKit

/// A child panel can sit above the sprite without resizing its saved window or drag target.
final class PlaybackBadge {
    private let panel: NSPanel
    private let button = NSButton()
    private let bars = PlaybackBars()
    var openSource: (() -> Void)?

    init() {
        let size = NSSize(width: 42, height: 22)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        button.title = ""
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel("Open playing source")
        button.target = self; button.action = #selector(open)
        button.frame = NSRect(origin: .zero, size: size)
        bars.frame = NSRect(x: 11, y: 6, width: 20, height: 11)
        bars.bounds.size = NSSize(width: 34, height: 19)
        bars.playingColor = .controlAccentColor
        bars.playing = true
        button.addSubview(bars)
        panel.contentView = button
    }

    @objc private func open() { openSource?() }

    func show(source: NowPlayingSnapshot, above head: NSPoint, in parent: NSWindow, opacity: CGFloat) {
        let size = panel.frame.size
        let display = parent.screen?.visibleFrame ?? parent.frame
        var origin = NSPoint(x: head.x - size.width / 2, y: head.y + 2)
        if origin.y + size.height > display.maxY {
            origin.y = display.maxY - size.height
            origin.x = head.x + parent.frame.width * 0.25
        }
        origin.x = min(max(origin.x, display.minX), display.maxX - size.width)
        origin.y = max(origin.y, display.minY)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        bars.playingColor = source.waveformColor
        button.toolTip = source.title
        button.setAccessibilityHelp(source.title)
        panel.alphaValue = opacity
        panel.level = parent.level
        if panel.parent !== parent {
            parent.addChildWindow(panel, ordered: .above)
            panel.orderFrontRegardless()
        }
        bars.visible = true
    }

    func hide() {
        guard let parent = panel.parent else { return }
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        bars.visible = false
    }
}
