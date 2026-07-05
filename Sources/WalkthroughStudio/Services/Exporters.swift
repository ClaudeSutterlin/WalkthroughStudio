import Foundation
import AppKit

enum Exporters {

    // MARK: PNG helpers

    static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// Redraw `image` into an exactly `pixelWidth` x `pixelHeight` bitmap and
    /// return PNG data. Normalizes away retina backing scale so App Store
    /// slots get pixel-exact files.
    static func pngData(from image: NSImage, pixelWidth: Int, pixelHeight: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Remove the top `fraction` of an image (used to strip the recording's
    /// status bar before frames ship in exports).
    static func cropTop(_ image: CGImage, fraction: Double) -> CGImage {
        guard fraction > 0.001 else { return image }
        let cropPx = Int(Double(image.height) * fraction)
        let rect = CGRect(x: 0, y: cropPx, width: image.width, height: image.height - cropPx)
        return image.cropping(to: rect) ?? image
    }

    static func dataURL(png: Data) -> String {
        "data:image/png;base64,\(png.base64EncodedString())"
    }

    /// Redraw `image` into an exact-pixel RGBA `CGImage` (normalizes retina scale).
    static func cgImage(from image: NSImage, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixelWidth, height: pixelHeight)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    // MARK: Output B — tutorialSteps payload (Section 7 contract)

    static func tutorialStepsTS(steps: [WalkthroughStep]) -> String {
        let included = steps.filter(\.includeInTutorial)
        var out = "export const tutorialSteps: TutorialStep[] = [\n"
        for step in included {
            out += "  {\n"
            out += "    id: '\(tsEscape(step.resolvedSlug))',\n"
            out += "    area: '\(tsEscape(step.area))',\n"
            out += "    title: '\(tsEscape(step.title))',\n"
            out += "    body: '\(tsEscape(step.body))',\n"
            out += "    image: '/pilot/\(tsEscape(step.resolvedSlug)).png',\n"
            out += "    alt: '\(tsEscape(step.alt))',\n"
            out += "  },\n"
        }
        out += "]\n"
        return out
    }

    static func tutorialStepsJSON(steps: [WalkthroughStep]) -> String {
        let included = steps.filter(\.includeInTutorial)
        let array = included.map { step -> [String: String] in
            [
                "id": step.resolvedSlug,
                "area": step.area,
                "title": step.title,
                "body": step.body,
                "image": "/pilot/\(step.resolvedSlug).png",
                "alt": step.alt,
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: array, options: [.prettyPrinted, .sortedKeys]
        ), let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    static func tutorialMarkdown(steps: [WalkthroughStep]) -> String {
        let included = steps.filter(\.includeInTutorial)
        var out = "# Walkthrough\n\n"
        for step in included {
            out += "## \(step.title)\n\n"
            if !step.area.isEmpty { out += "*\(step.area)*\n\n" }
            out += "\(step.body)\n\n"
            out += "![\(step.alt)](\(step.resolvedSlug).png)\n\n"
        }
        return out
    }

    private static func tsEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
