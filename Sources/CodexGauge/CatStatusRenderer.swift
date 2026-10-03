import AppKit
import UsageCore

/// Sample approved 32-frame sheets once, preserving pixel silhouettes and facial cutouts.
@MainActor
final class CatStatusRenderer {
    struct PixelMask {
        static let width = 48
        static let height = 24
        static let catWidth = 32
        let pixels: [Bool]
        var visiblePixelCount: Int { pixels.filter { $0 }.count }
        var catPixelCount: Int {
            pixels.enumerated().filter { $0.element && $0.offset % Self.width < Self.catWidth }.count
        }
        var bowlPixelCount: Int { visiblePixelCount - catPixelCount }
        var foodPixelCount: Int {
            pixels.enumerated().filter { $0.element && $0.offset % Self.width >= Self.catWidth && $0.offset / Self.width < 19 }.count
        }
    }

    let masks: [[PixelMask]]
    private struct RenderKey: Equatable {
        let percent: Double?
        let isDark: Bool
    }
    private var cachedKey: RenderKey?
    private var cachedImages: [NSImage] = []

    init() {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let decoded = CatBodyStage.allCases.map { stage -> [PixelMask] in
            let bundled = Bundle.main.url(forResource: stage.resourceName, withExtension: "png", subdirectory: "IdleCats")
            let source = bundled ?? sourceRoot.appendingPathComponent("Resources/IdleCats/\(stage.resourceName).png")
            guard let data = try? Data(contentsOf: source), let sheet = NSBitmapImageRep(data: data) else { return [] }
            return Self.decode(sheet, stage: stage)
        }
        guard let full = decoded.first?.first, let empty = decoded.last?.first else {
            masks = decoded
            return
        }
        // Use one approved bowl and mound as the scale reference for exact 100/75/50/25/0 food amounts.
        let food = full.pixels.indices.filter {
            full.pixels[$0] && $0 % PixelMask.width >= PixelMask.catWidth && $0 / PixelMask.width < 19
        }.sorted { a, b in
            let ay = a / PixelMask.width, by = b / PixelMask.width
            if ay != by { return ay > by }
            return abs(a % PixelMask.width - 40) < abs(b % PixelMask.width - 40)
        }
        let portions = [1.0, 0.75, 0.5, 0.25, 0.0]
        masks = decoded.enumerated().map { stage, frames in
            frames.map { mask in
                var pixels = mask.pixels
                for index in pixels.indices where index % PixelMask.width >= PixelMask.catWidth {
                    pixels[index] = index / PixelMask.width >= 19 && empty.pixels[index]
                }
                for index in food.prefix(Int(ceil(Double(food.count) * portions[stage]))) { pixels[index] = true }
                return PixelMask(pixels: pixels)
            }
        }
    }

    var hasValidFrames: Bool {
        masks.count == CatBodyStage.allCases.count && masks.allSatisfy {
            $0.count == CatIdleCycle.frameCount && $0.allSatisfy { $0.catPixelCount > 30 && $0.bowlPixelCount > 0 }
        }
    }

    private struct Bounds {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var count: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var midX: Double { Double(minX + maxX) / 2 }
    }

    /// Find the solid dish separately from the cat, without assuming identical sheet margins.
    private static func components(_ pixels: [Bool], width: Int, height: Int) -> [Bounds] {
        var visited = Array(repeating: false, count: pixels.count)
        var result: [Bounds] = []
        for first in pixels.indices where pixels[first] && !visited[first] {
            var stack = [first]
            visited[first] = true
            var bounds = Bounds(minX: first % width, maxX: first % width, minY: first / width, maxY: first / width, count: 0)
            while let point = stack.popLast() {
                let x = point % width, y = point / width
                bounds.minX = min(bounds.minX, x); bounds.maxX = max(bounds.maxX, x)
                bounds.minY = min(bounds.minY, y); bounds.maxY = max(bounds.maxY, y)
                bounds.count += 1
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard (0..<width).contains(nx), (0..<height).contains(ny) else { continue }
                    let next = ny * width + nx
                    if pixels[next], !visited[next] { visited[next] = true; stack.append(next) }
                }
            }
            result.append(bounds)
        }
        return result
    }

    /// Decode 8x4 cells at a higher working resolution, then align heads, paws and bowls.
    private static func decode(_ sheet: NSBitmapImageRep, stage: CatBodyStage) -> [PixelMask] {
        let width = 88, height = 64
        let cellWidth = Double(sheet.pixelsWide) / 8
        let cellHeight = Double(sheet.pixelsHigh) / 4
        let aspect = (cellWidth / Double(width)) / (cellHeight * 0.82 / Double(height))
        var fixedBowl: [Bool]?
        return (0..<CatIdleCycle.frameCount).map { frame in
            var source = Array(repeating: false, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let sx = min(sheet.pixelsWide - 1, Int((Double(frame % 8) + (Double(x) + 0.5) / Double(width)) * cellWidth))
                    let sy = min(sheet.pixelsHigh - 1, Int((Double(frame / 8) + 0.18 + 0.82 * (Double(y) + 0.5) / Double(height)) * cellHeight))
                    let color = sheet.colorAt(x: sx, y: sy)?.usingColorSpace(.deviceRGB)
                    source[y * width + x] = color.map { $0.alphaComponent >= 0.65 && min($0.redComponent, $0.greenComponent, $0.blueComponent) >= 0.7 } ?? false
                }
            }
            let parts = components(source, width: width, height: height)
            guard let body = parts.max(by: { $0.count < $1.count }),
                  let dish = parts.filter({ $0.midX > body.midX && $0.minX > Int(body.midX) && $0.maxY >= body.maxY - 6 && $0.width >= $0.height * 2 && $0.width > 5 }).max(by: { $0.maxX < $1.maxX }) else {
                return PixelMask(pixels: Array(repeating: false, count: PixelMask.width * PixelMask.height))
            }
            let split = min(dish.minX, (body.maxX + dish.minX) / 2)
            let catPoints = source.enumerated().compactMap { i, visible -> (x: Int, y: Int)? in
                visible && i % width < split ? (i % width, i / width) : nil
            }
            guard let top = catPoints.map(\.y).min(), let bottom = catPoints.map(\.y).max() else {
                return PixelMask(pixels: Array(repeating: false, count: PixelMask.width * PixelMask.height))
            }
            let head = catPoints.filter { $0.y < top + (bottom - top + 1) * 2 / 5 }
            let headCenter = Double((head.map(\.x).min() ?? body.minX) + (head.map(\.x).max() ?? body.maxX)) / 2
            let scaleY = 22.0 / Double(bottom - top + 1)
            let scaleX = scaleY * aspect
            var pixels = Array(repeating: false, count: PixelMask.width * PixelMask.height)
            func sample(_ sx: Double, _ sy: Double) -> Bool {
                let x = Int(sx.rounded()), y = Int(sy.rounded())
                return (0..<width).contains(x) && (0..<height).contains(y) && source[y * width + x]
            }
            for y in 0..<PixelMask.height {
                let sy = Double(bottom) - Double(22 - y) / scaleY
                // Normalize lower-body width in the slender stage; preserve the approved head and expression.
                let bellyScale = stage == .slender && sy >= Double(top + (bottom - top + 1) * 2 / 5) ? 0.88 : 1.0
                for x in 0..<PixelMask.catWidth {
                    let sx = headCenter + Double(x - 16) / (scaleX * bellyScale)
                    if sx < Double(split) { pixels[y * PixelMask.width + x] = sample(sx, sy) }
                }
            }
            if fixedBowl == nil {
                var bowl = Array(repeating: false, count: pixels.count)
                let foodTop = source.enumerated().compactMap { i, visible in visible && i % width >= split ? i / width : nil }.min() ?? dish.minY
                let bowlScaleX = 12.0 / Double(dish.width)
                let bowlScaleY = min(bowlScaleX / aspect, 20.0 / Double(dish.maxY - foodTop + 1))
                for y in 0..<PixelMask.height {
                    for x in 34..<PixelMask.width {
                        let sx = dish.midX + (Double(x) - 40.5) / bowlScaleX
                        let sy = Double(dish.maxY) - Double(22 - y) / bowlScaleY
                        bowl[y * PixelMask.width + x] = sx >= Double(split) && sample(sx, sy)
                    }
                }
                fixedBowl = bowl
            }
            return PixelMask(pixels: zip(pixels, fixedBowl!).map { $0.0 || $0.1 })
        }
    }

    /// Only quota and appearance changes recreate images; each animation tick swaps cached frames.
    func menuFrames(remainingPercent: Double?, isDark: Bool) -> [NSImage] {
        let percent = remainingPercent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
        let key = RenderKey(percent: percent, isDark: isDark)
        if key == cachedKey { return cachedImages }
        guard hasValidFrames else { return [GaugeStyle.menuImage(percent: percent, isDark: isDark)] }
        let stage = CatBodyStage.forRemainingPercent(percent).rawValue
        let gauge = GaugeStyle.menuImage(percent: percent, isDark: isDark)
        let frames = percent == nil ? [masks[stage][0]] : masks[stage]
        cachedImages = frames.map { mask in
            let image = NSImage(size: NSSize(width: 82, height: 24), flipped: false) { _ in
                Self.draw(mask, at: .zero, isDark: isDark, showsBowl: percent != nil)
                if percent == nil {
                    (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.5).setFill()
                    NSRect(x: 35, y: 7, width: 7, height: 1).fill()
                }
                gauge.draw(in: NSRect(x: 54, y: 6, width: 28, height: 12))
                return true
            }
            image.isTemplate = false
            return image
        }
        cachedKey = key
        return cachedImages
    }

    private static func draw(_ mask: PixelMask, at origin: NSPoint, isDark: Bool, showsBowl: Bool = true) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.shouldAntialias = false
        (isDark ? NSColor.white : NSColor.black).setFill()
        for y in 0..<PixelMask.height {
            for x in 0..<(showsBowl ? PixelMask.width : PixelMask.catWidth) where mask.pixels[y * PixelMask.width + x] {
                NSRect(x: origin.x + CGFloat(x), y: origin.y + CGFloat(PixelMask.height - y - 1), width: 1, height: 1).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Show all five stages in light and dark mode with enlarged real menu images.
    func writePreview(to url: URL) throws {
        guard hasValidFrames else { throw CocoaError(.fileReadCorruptFile) }
        let width = 600
        let height = 320
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: width * 4, bitsPerPixel: 32),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 300, height: height).fill()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(x: 300, y: 0, width: 300, height: height).fill()
        for (row, percent) in [100.0, 75, 50, 25, 0].enumerated() {
            for column in 0..<2 {
                let dark = column == 0
                let origin = NSPoint(x: CGFloat(column * 300 + 16), y: CGFloat((4 - row) * 64 + 8))
                menuFrames(remainingPercent: percent, isDark: dark)[0].draw(in: NSRect(x: origin.x, y: origin.y, width: 164, height: 48))
                (GaugeStyle.percent(percent) as NSString).draw(at: NSPoint(x: origin.x + 180, y: origin.y + 12), withAttributes: [.foregroundColor: dark ? NSColor.white : NSColor.black, .font: NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .regular)])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
