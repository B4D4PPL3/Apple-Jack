import AppKit

enum GlassBlur {
    static let preferenceKey = "liquidGlassBlur"
    static let defaultAmount = 0.0
    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultAmount }
        return (min(1, max(0, value)) * 100).rounded() / 100
    }
    static var saved: Double {
        normalized(UserDefaults.standard.object(forKey: preferenceKey) as? Double ?? defaultAmount)
    }

}

final class GlassBlurSettings: NSObject {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "0%")
    private var preview: ((Double) -> Void)?

    func present(initial: Double, preview: @escaping (Double) -> Void, completion: @escaping (Double?) -> Void) {
        self.preview = preview
        slider.doubleValue = GlassBlur.normalized(initial) * 100
        slider.target = self; slider.action = #selector(changed); slider.isContinuous = true
        slider.setAccessibilityLabel("Liquid Glass blur, percent")
        slider.toolTip = "Drag to soften the background while keeping text and controls sharp."
        slider.frame = NSRect(x: 0, y: 56, width: 340, height: 26)
        valueLabel.frame = NSRect(x: 350, y: 57, width: 60, height: 24)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 104))
        content.addSubview(slider); content.addSubview(valueLabel)
        for (text, x, width, alignment) in [("Native", CGFloat(0), CGFloat(80), NSTextAlignment.left),
                                          ("More blur", CGFloat(250), CGFloat(90), NSTextAlignment.right)] {
            let label = NSTextField(labelWithString: text)
            label.frame = NSRect(x: x, y: 34, width: width, height: 18)
            label.alignment = alignment; label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 11); content.addSubview(label)
        }
        let reset = NSButton(title: "Reset to 0%", target: self, action: #selector(resetBlur))
        reset.bezelStyle = .rounded; reset.frame = NSRect(x: 0, y: 0, width: 140, height: 28)
        content.addSubview(reset)
        let alert = NSAlert()
        alert.messageText = "Liquid Glass Blur"
        alert.informativeText = "Soften busy backgrounds while keeping text and controls sharp. 0% keeps the native glass effect. Drag to preview; Save keeps this amount on this Mac."
        alert.accessoryView = content
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = slider
        NSApp.activate(ignoringOtherApps: true)
        alert.presentInJack { [self] response in
            self.preview = nil
            completion(response == .alertFirstButtonReturn ? GlassBlur.normalized(slider.doubleValue / 100) : nil)
        }
    }
    @objc private func changed() {
        let amount = GlassBlur.normalized(slider.doubleValue / 100)
        slider.doubleValue = amount * 100
        valueLabel.stringValue = "\(Int((amount * 100).rounded()))%"
        preview?(amount)
    }
    @objc private func resetBlur() { slider.doubleValue = GlassBlur.defaultAmount * 100; changed() }
}
