import Foundation
import AppKit
import CoreGraphics

/// Replaces a recording's status bar with a pristine, Apple-style one:
/// the app's own background is extended over the band (sampled per-column
/// from the row just beneath it, so gradients survive), then a clean bar is
/// drawn on top — 9:41, signal/Wi-Fi/battery, and the Dynamic Island pill.
/// Layout stays pixel-identical to the recording; only the bar changes.
enum StatusBarStyler {

    // Geometry as fractions of the frame WIDTH (from 393pt iPhone metrics).
    private static let islandWidth: CGFloat = 0.322
    private static let islandHeight: CGFloat = 0.0955
    private static let islandTopInset: CGFloat = 0.0292
    private static let timeCenterX: CGFloat = 0.170
    private static let timeSize: CGFloat = 0.0455
    private static let iconSize: CGFloat = 0.042
    private static let iconCentersX: [CGFloat] = [0.782, 0.849, 0.922]
    private static let iconNames = ["cellularbars", "wifi", "battery.100percent"]

    /// Clean the status bar on a still frame. `fraction` is the band height
    /// as a fraction of the image height. If a notification banner floats over
    /// the bar (it extends below the band), the background fill is extended
    /// past it so no banner remnant ships.
    static func cleanStill(_ image: CGImage, fraction: Double, device: DeviceKind = .iphone) -> CGImage {
        let width = image.width, height = image.height
        let band = max(1, Int(Double(height) * fraction))
        guard band < height / 2,
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // A notification banner overlapping the bar reaches below the band —
        // extend the repainted region past it (still capped well above mid-screen).
        let fillRows = min(height / 2 - 2, firstCleanRow(in: image, below: band))

        // Extend the background: stretch the 2px row just below the repainted
        // region over it (per-column, so horizontal gradients continue
        // seamlessly). CGImage.cropping is top-left origin; CGContext drawing
        // is bottom-left.
        if let strip = image.cropping(to: CGRect(x: 0, y: fillRows + 1, width: width, height: 2)) {
            ctx.draw(strip, in: CGRect(x: 0, y: CGFloat(height - fillRows), width: CGFloat(width), height: CGFloat(fillRows)))
        }

        let useWhite = isDarkRow(image, row: fillRows + 1)
        drawBar(
            in: ctx,
            frameWidth: CGFloat(width),
            bandTopY: CGFloat(height),   // CG y of the band's top edge
            bandHeight: CGFloat(band),
            white: useWhite,
            device: device
        )
        return ctx.makeImage() ?? image
    }

    /// Transparent overlay (island + glyphs only, no background fill) sized to
    /// the band, for compositing over video. `width` = screen width in px,
    /// `bandHeight` = band height in px.
    static func overlay(width: Int, bandHeight: Int, white: Bool, device: DeviceKind = .iphone) -> CGImage? {
        guard width > 10, bandHeight > 4,
              let ctx = CGContext(
                data: nil, width: width, height: bandHeight, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: bandHeight))
        drawBar(in: ctx, frameWidth: CGFloat(width), bandTopY: CGFloat(bandHeight), bandHeight: CGFloat(bandHeight), white: white, device: device)
        return ctx.makeImage()
    }

    /// First row at/below `band` (top-left origin) that looks like plain app
    /// background again — i.e. past any floating notification banner.
    ///
    /// Heuristic: banners are inset from the screen edges and filled with a
    /// desaturated system material, so an obstructed row's middle differs
    /// strongly from its own margins while staying low-saturation. Full-width
    /// UI (nav bars, headers) covers the margins too, so it never matches, and
    /// brand-colored elements fail the saturation check. Without a banner the
    /// scan finds a clean run immediately and returns `band` unchanged.
    private static func firstCleanRow(in image: CGImage, below band: Int) -> Int {
        let width = image.width, height = image.height
        guard width > 120, band + 16 < height else { return band }
        // Rasterize only the scan window (top quarter-ish), not the full frame.
        let maxScan = min(height / 2 - 2, band + height / 4)
        guard let ctx = CGContext(
            data: nil, width: width, height: maxScan, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return band }
        // CG draws bottom-up: offset so the image's TOP maxScan rows fill the context.
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(maxScan - height), width: CGFloat(width), height: CGFloat(height)))
        guard let dataPtr = ctx.data else { return band }
        let bytesPerRow = ctx.bytesPerRow
        let pixels = dataPtr.bindMemory(to: UInt8.self, capacity: bytesPerRow * maxScan)

        func mean(row: Int, xs: [Int]) -> (r: Double, g: Double, b: Double) {
            // Bitmap-context memory is top-row-first, matching top-left rows.
            let base = row * bytesPerRow
            var r = 0.0, g = 0.0, b = 0.0
            for x in xs {
                let p = base + x * 4
                r += Double(pixels[p]); g += Double(pixels[p + 1]); b += Double(pixels[p + 2])
            }
            let n = Double(max(1, xs.count))
            return (r / n, g / n, b / n)
        }

        // Margin columns sit inside the screen edge but outside the banner's
        // ~8pt inset; middle columns sample the banner fill.
        let marginXs = [4, 8, 12, width - 13, width - 9, width - 5]
        let midXs = stride(from: Int(0.35 * Double(width)), to: Int(0.65 * Double(width)), by: max(2, width / 40)).map { $0 }

        let gapLimit = 16          // clean rows before we call the banner over
        var lastObstructed = -1
        var obstructedCount = 0
        var cleanRun = 0
        for row in band..<maxScan {
            let edge = mean(row: row, xs: marginXs)
            let mid = mean(row: row, xs: midXs)
            let diff = max(abs(edge.r - mid.r), abs(edge.g - mid.g), abs(edge.b - mid.b))
            let saturation = max(mid.r, mid.g, mid.b) - min(mid.r, mid.g, mid.b)
            if diff > 14, saturation < 40 {
                lastObstructed = row
                obstructedCount += 1
                cleanRun = 0
            } else {
                cleanRun += 1
                if cleanRun >= gapLimit { break }
            }
        }
        // A real banner is tall; a stray border/hairline shouldn't extend the mask.
        guard obstructedCount >= 10, lastObstructed >= band else { return band }
        return min(maxScan, lastObstructed + 8) // + a little for the drop shadow
    }

    /// Average luminance of the row just below the band — decides whether the
    /// bar's text/icons should be white (dark app) or black (light app).
    static func isDarkBelowBand(_ image: CGImage, fraction: Double) -> Bool {
        isDarkRow(image, row: max(1, Int(Double(image.height) * fraction)) + 1)
    }

    /// Average luminance of one row (top-left origin index).
    static func isDarkRow(_ image: CGImage, row: Int) -> Bool {
        guard let strip = image.cropping(to: CGRect(x: 0, y: min(row, image.height - 1), width: image.width, height: 1)) else {
            return false
        }
        let sampleW = 64
        guard let ctx = CGContext(
            data: nil, width: sampleW, height: 1, bitsPerComponent: 8,
            bytesPerRow: sampleW * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(strip, in: CGRect(x: 0, y: 0, width: sampleW, height: 1))
        guard let data = ctx.data else { return false }
        let ptr = data.bindMemory(to: UInt8.self, capacity: sampleW * 4)
        var total = 0.0
        for i in 0..<sampleW {
            let r = Double(ptr[i * 4]), g = Double(ptr[i * 4 + 1]), b = Double(ptr[i * 4 + 2])
            total += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }
        return (total / Double(sampleW)) < 0.5
    }

    // MARK: Drawing (CGContext, bottom-left origin)

    private static func drawBar(in ctx: CGContext, frameWidth w: CGFloat, bandTopY: CGFloat, bandHeight: CGFloat, white: Bool, device: DeviceKind) {
        let contentCenterY: CGFloat
        let timeFontSize: CGFloat
        let iconPointSize: CGFloat
        let timeX: CGFloat
        let iconXs: [CGFloat]

        if device == .iphone {
            // Dynamic Island — always black.
            let islandW = w * islandWidth
            let islandH = w * islandHeight
            let islandRect = CGRect(
                x: (w - islandW) / 2,
                y: bandTopY - w * islandTopInset - islandH,
                width: islandW,
                height: islandH
            )
            ctx.addPath(CGPath(roundedRect: islandRect, cornerWidth: islandH / 2, cornerHeight: islandH / 2, transform: nil))
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillPath()
            contentCenterY = islandRect.midY
            timeFontSize = w * timeSize
            iconPointSize = w * iconSize
            timeX = w * timeCenterX
            iconXs = iconCentersX.map { $0 * w }
        } else {
            // iPad: no island; a slim bar — time far left, glyphs far right,
            // sized to the (much shorter) band rather than the frame width.
            contentCenterY = bandTopY - bandHeight / 2
            timeFontSize = bandHeight * 0.62
            iconPointSize = bandHeight * 0.55
            timeX = w * 0.045
            iconXs = [0.905, 0.935, 0.965].map { $0 * w }
        }

        let color: NSColor = white ? .white : .black

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = previous }

        // 9:41 — Apple's canonical marketing time.
        let time = NSAttributedString(string: "9:41", attributes: [
            .font: NSFont.systemFont(ofSize: timeFontSize, weight: .semibold),
            .foregroundColor: color,
        ])
        let measured = time.size()
        time.draw(at: NSPoint(x: timeX - measured.width / 2, y: contentCenterY - measured.height / 2))

        // Signal / Wi-Fi / battery glyphs.
        let config = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .medium)
        for (name, centerX) in zip(iconNames, iconXs) {
            guard let symbol = (NSImage(systemSymbolName: name, accessibilityDescription: nil)
                    ?? NSImage(systemSymbolName: "battery.100", accessibilityDescription: nil))?
                .withSymbolConfiguration(config) else { continue }
            let tinted = tint(symbol, color: color)
            let size = tinted.size
            tinted.draw(
                in: NSRect(x: centerX - size.width / 2, y: contentCenterY - size.height / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1.0
            )
        }
    }

    private static func tint(_ image: NSImage, color: NSColor) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        return tinted
    }
}
