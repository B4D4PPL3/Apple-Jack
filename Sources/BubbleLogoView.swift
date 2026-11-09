import AppKit

final class BubbleLogoView: NSImageView {
    static let preference = "bubbleLogoStyle"
    static var style: String { UserDefaults.standard.string(forKey: preference) == "Classic" ? "Classic" : "Mono" }
    private var asset: String?

    func refresh() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let name = Self.style == "Classic" ? "Classic" : dark ? "White" : "Black"
        guard asset != name else { return }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "BubbleLogos"),
              let logo = NSImage(contentsOf: url) else { return }
        imageScaling = .scaleProportionallyUpOrDown
        image = logo
        asset = name
        setAccessibilityElement(true)
        setAccessibilityLabel("Apple Jack")
        setAccessibilityHelp("\(name) logo. Drag to move Jack.")
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}
