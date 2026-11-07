import CoreGraphics
import Foundation

// Native pixel artwork: the same renderer is used by the splash and previews.
enum SlimeArtwork {
    static let size = CGSize(width: 368, height: 144)

    static func draw(in context: CGContext, progress: Double, tick: Int) {
        let value = min(1, max(0, progress))
        context.saveGState()
        defer { context.restoreGState() }
        context.setShouldAntialias(false)
        let dark = color(0x101b15), border = color(0x395c30), green = color(0x7ce333)
        let bright = color(0xd1ff87), shadow = color(0x3c9826)
        pixelBox(context, CGRect(x: 0, y: 0, width: 368, height: 144), cut: 12, color: border)
        pixelBox(context, CGRect(x: 3, y: 3, width: 362, height: 138), cut: 12, color: dark)
        rect(context, 20, 137, 44, 3, bright)
        rect(context, 64, 137, 28, 3, green)
        text("APPLE JACK", at: CGPoint(x: 24, y: 112), scale: 2, color: color(0xe9f3dd), in: context)
        for index in 0..<3 {
            rect(context, CGFloat(310 + index * 12), 116, 6, 6, index == (tick / 3) % 3 ? bright : border)
        }

        let fillWidth = floor(308 * value / 4) * 4
        // Pixel drips grow and retract beneath the filled part of the bar.
        for (index, x) in [CGFloat(66), 142, 250].enumerated() where x + 10 < 30 + fillWidth {
            let depth = CGFloat([4, 8, 12, 8][(tick / 2 + index) % 4])
            rect(context, x - 2, 58 - depth, 12, depth + 8, border)
            rect(context, x, 60 - depth, 8, depth + 8, green)
            rect(context, x + 2, 60 - depth, 4, 2, shadow)
        }
        pixelBox(context, CGRect(x: 24, y: 60, width: 320, height: 32), cut: 4, color: border)
        rect(context, 28, 64, 312, 24, color(0x0a110d))
        for x in stride(from: 34, to: 338, by: 16) {
            rect(context, CGFloat(x), 68, 8, 16, color(0x192b1b))
        }
        if fillWidth > 0 {
            context.saveGState()
            context.clip(to: CGRect(x: 30, y: 66, width: fillWidth, height: 20))
            rect(context, 30, 66, fillWidth, 20, green)
            rect(context, 30, 66, fillWidth, 4, shadow)
            rect(context, 34, 82, max(0, fillWidth - 8), 4, bright)
            for index in 0..<8 {
                let x = CGFloat(42 + index * 40)
                let y = CGFloat(68 + (tick + index * 2) % 4 * 3)
                rect(context, x, y, 6, 6, shadow)
                rect(context, x + 2, y + 2, 2, 2, bright)
            }
            rect(context, 26 + fillWidth, 72, 4, 8, bright)
            context.restoreGState()
        }
        text(value >= 1 ? "READY" : "LOADING...", at: CGPoint(x: 24, y: 20), scale: 2, color: green, in: context)
        let percent = "\(Int(value * 100))%"
        text(percent, at: CGPoint(x: 344 - CGFloat(percent.count * 12 - 2), y: 20), scale: 2, color: bright, in: context)
    }

    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    private static func rect(_ context: CGContext, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ color: CGColor) {
        context.setFillColor(color)
        context.fill(CGRect(x: x, y: y, width: width, height: height))
    }
    private static func pixelBox(_ context: CGContext, _ box: CGRect, cut: CGFloat, color: CGColor) {
        rect(context, box.minX + cut, box.minY, box.width - cut * 2, box.height, color)
        rect(context, box.minX + cut / 3, box.minY + cut / 3, box.width - cut * 2 / 3, box.height - cut * 2 / 3, color)
        rect(context, box.minX, box.minY + cut, box.width, box.height - cut * 2, color)
    }
    private static func text(_ value: String, at origin: CGPoint, scale: CGFloat, color: CGColor, in context: CGContext) {
        for (column, character) in value.enumerated() {
            guard let rows = glyphs[character] else { continue }
            for (row, bits) in rows.enumerated() {
                for pixel in 0..<5 where bits & (1 << (4 - pixel)) != 0 {
                    rect(context, origin.x + CGFloat(column * 6 + pixel) * scale, origin.y + CGFloat(6 - row) * scale, scale, scale, color)
                }
            }
        }
    }
    private static let glyphs: [Character: [Int]] = [
        "A": [14,17,17,31,17,17,17], "C": [14,17,16,16,16,17,14],
        "D": [30,17,17,17,17,17,30], "E": [31,16,16,30,16,16,31],
        "G": [14,17,16,23,17,17,15], "I": [31,4,4,4,4,4,31],
        "J": [7,2,2,2,18,18,12], "K": [17,18,20,24,20,18,17],
        "L": [16,16,16,16,16,16,31], "N": [17,25,25,21,19,19,17],
        "O": [14,17,17,17,17,17,14], "P": [30,17,17,30,16,16,16],
        "R": [30,17,17,30,20,18,17], "Y": [17,17,10,4,4,4,4],
        ".": [0,0,0,0,0,0,4], "%": [25,25,2,4,8,19,19],
        "0": [14,17,19,21,25,17,14], "1": [4,12,4,4,4,4,14],
        "2": [14,17,1,2,4,8,31], "3": [30,1,1,14,1,1,30],
        "4": [2,6,10,18,31,2,2], "5": [31,16,16,30,1,1,30],
        "6": [14,16,16,30,17,17,14], "7": [31,1,2,4,8,8,8],
        "8": [14,17,17,14,17,17,14], "9": [14,17,17,15,1,1,14]
    ]
}
