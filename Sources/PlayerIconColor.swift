import AppKit

enum PlayerIconColor {
    private static let cache = NSCache<NSString, NSColor>()

    static func color(for bundleID: String) -> NSColor {
        guard !bundleID.isEmpty else { return .controlAccentColor }
        let key = bundleID as NSString
        if let color = cache.object(forKey: key) { return color }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return .controlAccentColor }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        let color: NSColor
        if ["youtube", "youtube music"].contains(name) {
            color = .systemRed
        } else {
            color = representativeColor(NSWorkspace.shared.icon(forFile: url.path)) ?? .controlAccentColor
        }
        cache.setObject(color, forKey: key)
        return color
    }

    // Ignore transparent borders and neutral highlights and shadows. Collect
    // nearby hues so an icon's main color wins over small multicolored details.
    static func representativeColor(_ icon: NSImage) -> NSColor? {
        let size = 24
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var bins = Array(repeating: (count: 0, red: CGFloat(0), green: CGFloat(0), blue: CGFloat(0)), count: 12)
        for y in 0..<size {
            for x in 0..<size {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.65,
                      c.saturationComponent > 0.25, c.brightnessComponent > 0.25 else { continue }
                let i = Int((c.hueComponent * 12).rounded()) % 12
                bins[i].count += 1
                bins[i].red += c.redComponent
                bins[i].green += c.greenComponent
                bins[i].blue += c.blueComponent
            }
        }
        guard let best = bins.max(by: { $0.count < $1.count }), best.count > 0 else { return nil }
        let count = CGFloat(best.count)
        return NSColor(srgbRed: best.red / count, green: best.green / count, blue: best.blue / count, alpha: 1)
    }
}
