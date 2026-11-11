import AppKit

final class BubbleLogoView: NSView {
    static let preference = "bubbleLogoStyle"
    static let customTextPreference = "bubbleLogoCustomText"
    static let styles = ["Mono", "Classic", "App Icon", "Apple Jack Name", "Custom Text"]
    static var style: String {
        let saved = UserDefaults.standard.string(forKey: preference) ?? "Mono"
        return styles.contains(saved) ? saved : "Mono"
    }
    static func normalizedText(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var customText: String {
        let value = normalizedText(UserDefaults.standard.string(forKey: customTextPreference) ?? "")
        return value.isEmpty ? "Apple Jack" : value
    }
    private let logo = NSImageView()
    private let label = NSTextField(labelWithString: "Apple Jack")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        logo.imageScaling = .scaleProportionallyUpOrDown
        label.font = .boldSystemFont(ofSize: 20)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(logo); addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        logo.setAccessibilityElement(false); label.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.isHidden ? 40 : min(160, max(40, label.fittingSize.width)), height: 40)
    }

    override func layout() {
        super.layout()
        let side = min(40, bounds.width, bounds.height)
        logo.frame = NSRect(x: bounds.minX, y: bounds.midY - side / 2, width: side, height: side)
        let height = min(bounds.height, label.fittingSize.height)
        label.frame = NSRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    // Keep the entire heading a drag surface, including the text/image children.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    func refresh() {
        let style = Self.style
        let isText = style == "Apple Jack Name" || style == "Custom Text"
        label.isHidden = !isText; logo.isHidden = isText
        label.stringValue = style == "Custom Text" ? Self.customText : "Apple Jack"
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = style == "Classic" ? "Classic" : dark ? "White" : "Black"
        if style == "App Icon" { logo.image = NSApp.applicationIconImage }
        else if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "BubbleLogos") {
            logo.image = NSImage(contentsOf: url)
        }
        setAccessibilityLabel(isText ? label.stringValue : "Apple Jack")
        setAccessibilityHelp("\(isText ? style : style == "App Icon" ? "App icon" : name + " logo"). Drag to move Jack.")
        toolTip = isText ? label.stringValue + " — Drag to move Jack and his speech bubble." : "Drag to move Jack and his speech bubble."
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}
