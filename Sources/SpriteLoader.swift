import AppKit
import ImageIO

// The original Apple Jack library sheet is the nine-row, 192 × 208 format.
enum PetAnimation: String, CaseIterable {
    case idle, right = "running-right", left = "running-left", waving, jumping, failed, waiting, running, review

    var row: Int { Self.allCases.firstIndex(of: self)! }
    var count: Int { [6, 8, 8, 4, 5, 8, 6, 6, 6][row] }

    func duration(_ frame: Int) -> TimeInterval {
        let last = frame == count - 1
        switch self {
        case .right, .left, .running: return last ? 0.220 : 0.120
        case .jumping, .waving: return last ? 0.280 : 0.140
        case .failed: return last ? 0.240 : 0.140
        case .waiting: return last ? 0.260 : 0.150
        case .review: return last ? 0.280 : 0.150
        case .idle: return [1.68, 0.66, 0.66, 0.84, 0.84, 1.92][frame]
        }
    }

    var threeCycles: TimeInterval { 3 * (0..<count).reduce(0.0) { $0 + duration($1) } }
}

struct SpriteFrame {
    let image: CGImage
    // Frame placement relative to the bottom center of the character canvas.
    let boundsAtFeet: CGRect
}

struct LoadedSpriteSheet {
    let image: CGImage
    let frames: [SpriteFrame]
    var frameCount: Int { frames.count }
}

enum SpriteLoader {
    struct LoadError: LocalizedError {
        let name: String
        var errorDescription: String? { "Couldn’t prepare the \(name) animation. Try reinstalling Apple Jack." }
    }

    static func loadAtlas(_ url: URL, petName: String = "Apple Jack", progress: (Double) -> Void) throws -> [String: LoadedSpriteSheet] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
              atlas.width == 1536, atlas.height == 1872 else { throw LoadError(name: petName) }
        return try splitAtlas(atlas, progress: progress)
    }

    static func splitAtlas(_ atlas: CGImage, progress: (Double) -> Void) throws -> [String: LoadedSpriteSheet] {
        var result: [String: LoadedSpriteSheet] = [:]
        let cell = CGSize(width: 192, height: 208)
        for pose in PetAnimation.allCases {
            let region = CGRect(x: 0, y: CGFloat(pose.row) * cell.height, width: CGFloat(pose.count) * cell.width, height: cell.height)
            guard let strip = atlas.cropping(to: region) else { throw LoadError(name: pose.rawValue) }
            let frames = try (0..<pose.count).map { column -> SpriteFrame in
                let rect = CGRect(origin: CGPoint(x: CGFloat(column) * cell.width, y: 0), size: cell)
                guard let image = strip.cropping(to: rect) else { throw LoadError(name: pose.rawValue) }
                // Keeping the whole cell preserves the sheet's original jump height and foot placement.
                return SpriteFrame(image: image, boundsAtFeet: CGRect(origin: CGPoint(x: -cell.width / 2, y: 0), size: cell))
            }
            result[pose.rawValue] = LoadedSpriteSheet(image: strip, frames: frames)
            progress(Double(pose.row + 1) / Double(PetAnimation.allCases.count))
        }
        return result
    }

    // All mutable bitmap objects belong to this worker. Only immutable CGImages
    // cross back to the main thread, where the pet's NSImages are installed.
    static func load(from resources: URL, progress: (Double) -> Void) throws -> [String: LoadedSpriteSheet] {
        let atlas = resources.appendingPathComponent("Sprites/AppleJackPet.png")
        if FileManager.default.fileExists(atPath: atlas.path) {
            return try loadAtlas(atlas, progress: progress)
        }
        // Older source bundles used by the legacy sprite exporters have separate strips.
        // Registration marks for the bundled artwork, in source pixels. The shoes
        // stay planted while the head, hands and overall silhouette change shape.
        // Use one scale for each strip, including its crouching and sitting poses.
        let animations: [(name: String, standingShoeWidth: CGFloat, soleCentersX: [CGFloat])] = [
            ("idle", 170, [163, 479.5, 800, 1110.5, 1435.5, 1747]),
            ("review", 190, [174, 541, 893, 1259.5, 1587, 1953]),
            ("waiting", 183, [207.5, 547, 898.5, 1251.5, 1606, 1961.5]),
            ("failed", 156, [154, 430, 690.5, 912.5, 1178, 1470, 1770, 2027.5]),
            ("waving", 223, [191.5, 626, 1061.5, 1497.5])
        ]
        var sheets: [String: LoadedSpriteSheet] = [:]
        for (index, animation) in animations.enumerated() {
            let (name, standingShoeWidth, soleCentersX) = animation
            sheets[name] = try autoreleasepool {
                let url = resources.appendingPathComponent("Sprites/\(name).png")
                guard let data = try? Data(contentsOf: url), let source = NSBitmapImageRep(data: data),
                      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: source.pixelsWide * 4, bitsPerPixel: 32), let pixels = bitmap.bitmapData else { throw LoadError(name: name) }
                var tops = Array(repeating: source.pixelsHigh, count: source.pixelsWide)
                var bottoms = Array(repeating: -1, count: source.pixelsWide)
                for y in 0..<source.pixelsHigh {
                    for x in 0..<source.pixelsWide {
                        guard let c = source.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw LoadError(name: name) }
                        let blue = c.blueComponent > 0.45 && c.blueComponent > c.redComponent * 1.6 && c.blueComponent > c.greenComponent * 1.6
                        let i = y * bitmap.bytesPerRow + x * 4
                        // This bitmap uses premultiplied RGBA. Alpha zero also
                        // requires RGB zero; retaining the blue backing color
                        // produces invalid pixels that can show up when scaled.
                        let alpha = blue ? 0 : min(1, max(0, c.alphaComponent))
                        pixels[i] = UInt8(min(1, max(0, c.redComponent)) * alpha * 255)
                        pixels[i+1] = UInt8(min(1, max(0, c.greenComponent)) * alpha * 255)
                        pixels[i+2] = UInt8(min(1, max(0, c.blueComponent)) * alpha * 255)
                        pixels[i+3] = UInt8(alpha * 255)
                        if pixels[i+3] > 0 {
                            tops[x] = min(tops[x], y)
                            bottoms[x] = y
                        }
                    }
                    if y % 32 == 0 {
                        progress((Double(index) + Double(y) / Double(source.pixelsHigh)) / Double(animations.count))
                    }
                }
                // Transparent columns separate poses. The source strips have
                // uneven spacing; equal-width cuts can clip a hand or a shoe.
                var regions: [CGRect] = []
                var region = CGRect.null
                for x in 0...source.pixelsWide {
                    if x < source.pixelsWide, bottoms[x] >= tops[x] {
                        region = region.union(CGRect(x: x, y: tops[x], width: 1, height: bottoms[x] - tops[x] + 1))
                    } else if !region.isNull {
                        regions.append(region)
                        region = .null
                    }
                }
                guard regions.count == soleCentersX.count, let cg = bitmap.cgImage else { throw LoadError(name: name) }
                let frames = try zip(regions, soleCentersX).map { rect, center -> SpriteFrame in
                    guard center >= rect.minX, center < rect.maxX, let image = cg.cropping(to: rect) else { throw LoadError(name: name) }
                    let bounds = CGRect(x: (rect.minX - center) / standingShoeWidth, y: 0,
                                        width: rect.width / standingShoeWidth, height: rect.height / standingShoeWidth)
                    return SpriteFrame(image: image, boundsAtFeet: bounds)
                }
                // Keep the transparent, vertically trimmed strip for the existing sprite exporter.
                let extent = regions.reduce(CGRect.null) { $0.union($1) }
                guard let strip = cg.cropping(to: CGRect(x: 0, y: extent.minY, width: CGFloat(cg.width), height: extent.height)) else { throw LoadError(name: name) }
                return LoadedSpriteSheet(image: strip, frames: frames)
            }
            progress(Double(index + 1) / Double(animations.count))
        }
        return sheets
    }
}
