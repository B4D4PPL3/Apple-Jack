import AppKit

enum JackIcon {
    static func image(named name: String, accessibilityDescription: String?) -> NSImage? {
        if #available(macOS 11, *), let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) {
            return image
        }
        let glyphs = ["leaf.fill": "♣", "xmark": "×", "xmark.circle.fill": "⊗",
                      "doc.on.clipboard": "▤", "doc.on.clipboard.fill": "▤",
                      "bubble.left.and.bubble.right": "❝", "music.note": "♫",
                      "speaker.wave.2": "◖", "backward.end.fill": "◀",
                      "forward.end.fill": "▶", "playpause.fill": "▸Ⅱ",
                      "app": "▣", "folder": "▱", "globe": "◎", "square.stack.3d.up": "▧"]
        let glyph = (glyphs[name] ?? "•") as NSString
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.black]
            let textSize = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }
}
