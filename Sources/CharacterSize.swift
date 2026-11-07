import AppKit

enum CharacterSize {
    static let preferenceKey = "characterScale"
    static let baseSide: CGFloat = 240
    static let minimum = 0.5
    static let maximum = 2.0

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return (min(maximum, max(minimum, value)) * 100).rounded() / 100
    }

    static var saved: Double {
        normalized(UserDefaults.standard.object(forKey: preferenceKey) as? Double ?? 1)
    }

    static func frame(scale: Double, anchoredTo original: NSRect, visibleFrame: NSRect?) -> NSRect {
        let side = baseSide * normalized(scale)
        var frame = NSRect(x: original.midX - side / 2, y: original.minY, width: side, height: side)
        if let screen = visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - side))
            frame.origin.y = min(max(frame.minY, screen.minY), max(screen.minY, screen.maxY - side))
        }
        return frame
    }

    static func bubbleAnchor(in bounds: NSRect) -> NSRect {
        let scale = bounds.width / baseSide
        return NSRect(x: bounds.minX + 85 * scale, y: bounds.minY + 170 * scale,
                      width: 70 * scale, height: 30 * scale)
    }
}

enum CharacterOpacity {
    static let preferenceKey = "characterOpacity"

    static var saved: Double {
        let value = UserDefaults.standard.object(forKey: preferenceKey) as? Double ?? 1
        guard value.isFinite else { return 1 }
        return (min(1, max(0, value)) * 100).rounded() / 100
    }
}

final class CharacterSliderSettings: NSObject {
    private let slider: NSSlider
    private let title: String
    private let instructions: String

    init(title: String, percentRange: ClosedRange<Double>, instructions: String) {
        self.title = title
        self.instructions = instructions
        slider = NSSlider(value: 100, minValue: percentRange.lowerBound,
                          maxValue: percentRange.upperBound, target: nil, action: nil)
        super.init()
    }

    static func size() -> CharacterSliderSettings {
        CharacterSliderSettings(title: "Character Size", percentRange: (CharacterSize.minimum * 100)...(CharacterSize.maximum * 100),
                                instructions: "Move the slider to preview Jack’s size. Save keeps this size on this Mac.")
    }

    static func opacity() -> CharacterSliderSettings {
        CharacterSliderSettings(title: "Character Opacity", percentRange: 0...100,
                                instructions: "Lower the slider to make Jack more transparent. At 0%, you can still find him using the menu-bar leaf or his keyboard shortcut.")
    }

    private let valueLabel = NSTextField(labelWithString: "100%")
    private var preview: ((Double) -> Void)?

    // The caller previews changes, commits on Save, and restores on Cancel.
    func run(initial: Double, preview: @escaping (Double) -> Void) -> Double? {
        self.preview = preview
        defer { self.preview = nil }
        slider.doubleValue = initial.isFinite ? (initial * 100).rounded() : 100
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Apple Jack \(title.lowercased()), percent")
        slider.toolTip = instructions
        slider.frame = NSRect(x: 0, y: 56, width: 340, height: 26)
        valueLabel.frame = NSRect(x: 350, y: 57, width: 60, height: 24)
        valueLabel.alignment = .right
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        valueLabel.stringValue = "\(Int(slider.doubleValue))%"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 104))
        content.addSubview(slider)
        content.addSubview(valueLabel)
        let small = NSTextField(labelWithString: "\(Int(slider.minValue))%")
        small.frame = NSRect(x: 0, y: 34, width: 50, height: 18)
        small.textColor = .secondaryLabelColor
        small.font = .systemFont(ofSize: 11)
        let large = NSTextField(labelWithString: "\(Int(slider.maxValue))%")
        large.frame = NSRect(x: 290, y: 34, width: 50, height: 18)
        large.alignment = .right
        large.textColor = .secondaryLabelColor
        large.font = .systemFont(ofSize: 11)
        content.addSubview(small)
        content.addSubview(large)
        let reset = NSButton(title: "Reset to 100%", target: self, action: #selector(resetToDefault))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 0, y: 0, width: 140, height: 28)
        content.addSubview(reset)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = instructions
        alert.accessoryView = content
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = slider
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return slider.doubleValue.rounded() / 100
    }

    @objc private func changed() {
        let percent = slider.doubleValue.rounded()
        slider.doubleValue = percent
        valueLabel.stringValue = "\(Int(percent))%"
        preview?(percent / 100)
    }

    @objc private func resetToDefault() { slider.doubleValue = 100; changed() }
}
