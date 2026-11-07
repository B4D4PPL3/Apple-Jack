import AppKit

enum GlassFrost {
    static let preferenceKey = "liquidGlassFrost"
    static let defaultAmount = 0.25
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultAmount }
        return (min(1, max(0, value)) * 100).rounded() / 100
    }
    static var saved: Double {
        normalized(UserDefaults.standard.object(forKey: preferenceKey) as? Double ?? defaultAmount)
    }
    // A neutral tint over the native clear glass reduces background contrast
    // without changing the text opacity or returning to the heavy regular glass.
    static func tintAlpha(_ amount: Double) -> CGFloat { CGFloat(normalized(amount)) * 0.72 }
}

final class GlassFrostSettings: NSObject {
    private let slider = NSSlider(value: 25, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "25%")
    private var preview: ((Double) -> Void)?

    func run(initial: Double, preview: @escaping (Double) -> Void) -> Double? {
        self.preview = preview
        defer { self.preview = nil }
        slider.doubleValue = GlassFrost.normalized(initial) * 100
        slider.target = self; slider.action = #selector(changed); slider.isContinuous = true
        slider.setAccessibilityLabel("Liquid Glass frost, percent")
        slider.toolTip = "Drag from clear glass to more frost for easier reading."
        slider.frame = NSRect(x: 0, y: 56, width: 340, height: 26)
        valueLabel.frame = NSRect(x: 350, y: 57, width: 60, height: 24)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 104))
        content.addSubview(slider); content.addSubview(valueLabel)
        for (text, x, width, alignment) in [("Clear", CGFloat(0), CGFloat(80), NSTextAlignment.left),
                                          ("More frost", CGFloat(250), CGFloat(90), NSTextAlignment.right)] {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: x, y: 34, width: width, height: 18)
            label.alignment = alignment; label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11); content.addSubview(label)
        }
        let reset = NSButton(title: "Reset to 25%", target: self, action: #selector(resetFrost))
        reset.bezelStyle = .rounded; reset.frame = NSRect(x: 0, y: 0, width: 140, height: 28)
        content.addSubview(reset)
        let alert = NSAlert()
        alert.messageText = "Liquid Glass Frost"
        alert.informativeText = "Add a soft tint for easier reading over busy backgrounds. Drag to preview; Save keeps this amount on this Mac."
        alert.accessoryView = content
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = slider
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return GlassFrost.normalized(slider.doubleValue / 100)
    }
    @objc private func changed() {
        let amount = GlassFrost.normalized(slider.doubleValue / 100)
        slider.doubleValue = amount * 100
        valueLabel.stringValue = "\(Int((amount * 100).rounded()))%"
        preview?(amount)
    }
    @objc private func resetFrost() { slider.doubleValue = GlassFrost.defaultAmount * 100; changed() }
}
