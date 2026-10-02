import AppKit
import UsageCore

/// Decode the approved sprite sheet once, then render crisp menu-size pixel silhouettes.
@MainActor
final class CatStatusRenderer {
    struct PixelMask {
        static let width = 36
        static let height = 24
        let pixels: [Bool]
        var visiblePixelCount: Int { pixels.reduce(0) { $0 + ($1 ? 1 : 0) } }
    }

    let masks: [[PixelMask]]

    init() {
        let bundled = Bundle.main.url(forResource: "CatSpriteSheet", withExtension: "png")
        // SwiftPM runs keep artwork in the workspace; packaged apps use their own bundle.
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = bundled ?? sourceRoot.appendingPathComponent("Resources/CatSpriteSheet.png")
        guard let data = try? Data(contentsOf: source), let sheet = NSBitmapImageRep(data: data) else {
            masks = []
            return
        }
        masks = Self.decode(sheet)
    }

    var hasValidFrames: Bool {
        masks.count == 4 && masks.allSatisfy { $0.count == CatRunCycle.frameCount && $0.allSatisfy { $0.visiblePixelCount > 0 } }
    }

    /// Sample at a fixed grid. Ignore transparent background and dark eye cutouts.
    private static func decode(_ sheet: NSBitmapImageRep) -> [[PixelMask]] {
        let cellWidth = Double(sheet.pixelsWide) / 4
        let cellHeight = Double(sheet.pixelsHigh) / 4
        return (0..<4).map { stage in
            (0..<CatRunCycle.frameCount).map { frame in
                var pixels = [Bool]()
                pixels.reserveCapacity(PixelMask.width * PixelMask.height)
                for y in 0..<PixelMask.height {
                    for x in 0..<PixelMask.width {
                        let sourceX = Int((Double(frame) + (Double(x) + 0.5) / Double(PixelMask.width)) * cellWidth)
                        let sourceY = Int((Double(stage) + (Double(y) + 0.5) / Double(PixelMask.height)) * cellHeight)
                        let color = sheet.colorAt(x: sourceX, y: sourceY)?.usingColorSpace(.deviceRGB)
                        let visible = color.map {
                            $0.alphaComponent >= 0.65 && min($0.redComponent, $0.greenComponent, $0.blueComponent) >= 0.7
                        } ?? false
                        pixels.append(visible)
                    }
                }
                return PixelMask(pixels: pixels)
            }
        }
    }

    /// Cache four complete images when quota or appearance changes; ticks only swap images.
    func menuFrames(remainingPercent: Double?, isDark: Bool) -> [NSImage] {
        guard hasValidFrames else { return [GaugeStyle.menuImage(percent: remainingPercent, isDark: isDark)] }
        let stage = CatBodyStage.forRemainingPercent(remainingPercent).rawValue
        let gauge = GaugeStyle.menuImage(percent: remainingPercent, isDark: isDark)
        return masks[stage].map { mask in
            let image = NSImage(size: NSSize(width: 70, height: 24), flipped: false) { _ in
                Self.draw(mask, at: .zero, isDark: isDark)
                gauge.draw(in: NSRect(x: 42, y: 6, width: 28, height: 12))
                return true
            }
            image.isTemplate = false
            return image
        }
    }

    /// Integer-sized squares keep the sprite sharp on standard and Retina displays.
    private static func draw(_ mask: PixelMask, at origin: NSPoint, isDark: Bool) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        (isDark ? NSColor.white : NSColor.black).setFill()
        for y in 0..<PixelMask.height {
            for x in 0..<PixelMask.width where mask.pixels[y * PixelMask.width + x] {
                NSRect(x: origin.x + CGFloat(x), y: origin.y + CGFloat(PixelMask.height - y - 1), width: 1, height: 1).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Export a visual diagnostic of all stages and poses without reading the desktop.
    func writePreview(to url: URL) throws {
        guard hasValidFrames else { throw CocoaError(.fileReadCorruptFile) }
        let width = 560
        let height = 192
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for stage in 0..<4 {
            let percent = [100.0, 75, 50, 25][stage]
            for frame in 0..<CatRunCycle.frameCount {
                let origin = NSPoint(x: frame * 140 + 8, y: (3 - stage) * 48 + 12)
                Self.draw(masks[stage][frame], at: origin, isDark: true)
                GaugeStyle.menuImage(percent: percent, isDark: true).draw(in: NSRect(x: origin.x + 42, y: origin.y + 6, width: 28, height: 12))
                let text = GaugeStyle.percent(percent) as NSString
                text.draw(at: NSPoint(x: origin.x + 78, y: origin.y + 4), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
