import Foundation
import AppKit
import CoreGraphics

/// Geometry + background rendering for the 16:9 branded video wrapper.
///
/// The recording is portrait; we place it inside a device bezel on a landscape
/// (1920×1080) branded canvas — an expanded version of the App Store slide.
/// All rects use a top-left origin (CoreGraphics image space).
struct VideoFrameLayout {
    static let canvas = CGSize(width: 1920, height: 1080)

    /// Default portrait screen aspect (the App Store template's `1206 / 2622`).
    static let screenAspect: CGFloat = 1206.0 / 2622.0

    let phoneRect: CGRect
    let padding: CGFloat
    let bezelRadius: CGFloat
    let screenRadius: CGFloat
    let textRect: CGRect
    let textTop: CGFloat
    let textAlign: String

    /// Inner screen rect (where the video is composited).
    var screenRect: CGRect { phoneRect.insetBy(dx: padding, dy: padding) }

    /// Bezel proportions relative to the device width.
    private static func bezel(for device: DeviceKind) -> (pad: CGFloat, radius: CGFloat) {
        switch device {
        case .iphone: return (16.0 / 880.0, 84.0 / 880.0)
        case .ipad: return (0.024, 0.036)
        case .computer: return (0.010, 0.018)
        }
    }

    init(
        canvas: CGSize = VideoFrameLayout.canvas,
        device: DeviceKind = .iphone,
        videoAspect: CGFloat = VideoFrameLayout.screenAspect
    ) {
        let aspect = videoAspect > 0 ? videoAspect : Self.screenAspect
        let proportions = Self.bezel(for: device)

        if aspect < 1 {
            // Portrait recording: device on the right, text column on the left.
            let screenHeight = canvas.height - 140
            let screenWidth = screenHeight * aspect
            let phoneWidth = screenWidth / (1 - 2 * proportions.pad)
            let pad = phoneWidth * proportions.pad
            let phoneHeight = screenHeight + 2 * pad

            let rightMargin: CGFloat = 150
            let phoneX = canvas.width - phoneWidth - rightMargin
            let phoneY = (canvas.height - phoneHeight) / 2

            self.phoneRect = CGRect(x: phoneX, y: phoneY, width: phoneWidth, height: phoneHeight)
            self.padding = pad
            self.bezelRadius = phoneWidth * proportions.radius
            self.screenRadius = max(6, bezelRadius - pad)

            let textLeft: CGFloat = 130
            let textWidth = phoneX - textLeft - 90
            self.textRect = CGRect(x: textLeft, y: 0, width: max(200, textWidth), height: canvas.height)
            self.textTop = phoneRect.midY - 210
            self.textAlign = "left"
        } else {
            // Landscape recording (iPad landscape / computer): text banner on
            // top, wide device centered beneath it. The band fits wordmark +
            // one-line headline + subhead with room to breathe.
            let textBandHeight: CGFloat = 380
            let bottomMargin: CGFloat = 50
            var screenHeight = canvas.height - textBandHeight - bottomMargin
            var screenWidth = screenHeight * aspect
            let maxWidth = canvas.width - 260
            if screenWidth > maxWidth {
                screenWidth = maxWidth
                screenHeight = screenWidth / aspect
            }
            let phoneWidth = screenWidth / (1 - 2 * proportions.pad)
            let pad = phoneWidth * proportions.pad
            let phoneHeight = screenHeight + 2 * pad

            let phoneX = (canvas.width - phoneWidth) / 2
            let phoneY = textBandHeight + (canvas.height - textBandHeight - bottomMargin - phoneHeight) / 2

            self.phoneRect = CGRect(x: phoneX, y: max(textBandHeight - 20, phoneY), width: phoneWidth, height: phoneHeight)
            self.padding = pad
            self.bezelRadius = phoneWidth * proportions.radius
            self.screenRadius = max(6, bezelRadius - pad)

            let textWidth: CGFloat = 1500
            self.textRect = CGRect(x: (canvas.width - textWidth) / 2, y: 0, width: textWidth, height: textBandHeight)
            self.textTop = 40
            self.textAlign = "center"
        }
    }

    func templateHTML(headlineHTML: String, subHTML: String, theme: BrandTheme = BrandTheme()) -> String {
        guard var html = TemplateStore.load("video-frame-template") else {
            return "<html><body>Template missing</body></html>"
        }
        let map: [String: String] = [
            "{{WIDTH}}": String(Int(VideoFrameLayout.canvas.width)),
            "{{HEIGHT}}": String(Int(VideoFrameLayout.canvas.height)),
            "{{PHONE_LEFT}}": fmt(phoneRect.minX),
            "{{PHONE_TOP}}": fmt(phoneRect.minY),
            "{{PHONE_W}}": fmt(phoneRect.width),
            "{{PHONE_H}}": fmt(phoneRect.height),
            "{{PAD}}": fmt(padding),
            "{{BEZEL_R}}": fmt(bezelRadius),
            "{{SCREEN_R}}": fmt(screenRadius),
            "{{TEXT_LEFT}}": fmt(textRect.minX),
            "{{TEXT_TOP}}": fmt(textTop),
            "{{TEXT_W}}": fmt(textRect.width),
            "{{TEXT_ALIGN}}": textAlign,
            "{{HEADLINE}}": headlineHTML,
            "{{SUB}}": subHTML,
            "{{THEME_CSS}}": theme.css(),
            "{{WORDMARK}}": theme.wordmarkHTML,
        ]
        for (key, value) in map { html = html.replacingOccurrences(of: key, with: value) }
        return html
    }

    private func fmt(_ value: CGFloat) -> String { String(format: "%.1f", value) }
}

/// Everything the compositor needs to wrap a recording in the branded frame.
/// The background is a timeline: one branded canvas per step, so the headline
/// and subhead follow the step the video is currently showing.
struct VideoFraming {
    struct Slide {
        var start: Double         // seconds into the video where this text takes over
        var headlineHTML: String
        var subHTML: String
    }

    struct Segment {
        var start: Double
        var background: CGImage   // full 1920×1080 branded canvas (empty screen)
    }

    /// How the recording's status bar is handled inside the device.
    enum StatusBarTreatment {
        case off
        case crop(Double)                              // cut the band; cover-fit the rest
        case clean(fraction: Double, overlay: CGImage) // extend bg + synthetic bar
    }

    var segments: [Segment]       // sorted by start; first entry covers from 0
    var canvas: CGSize
    var screenRect: CGRect        // top-left origin, where the video goes
    var screenRadius: CGFloat
    var statusBar: StatusBarTreatment = .off

    /// Render one branded background per slide offscreen (WKWebView) at exact
    /// pixel size. Consecutive slides with identical text are collapsed, and
    /// identical text is rendered once and reused.
    @MainActor
    static func make(
        slides: [Slide],
        theme: BrandTheme = BrandTheme(),
        device: DeviceKind = .iphone,
        videoAspect: CGFloat = VideoFrameLayout.screenAspect,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> VideoFraming {
        let layout = VideoFrameLayout(device: device, videoAspect: videoAspect)
        let renderer = BrandedRenderer()
        let width = Int(VideoFrameLayout.canvas.width)
        let height = Int(VideoFrameLayout.canvas.height)

        var ordered = slides.sorted { $0.start < $1.start }
        if ordered.isEmpty {
            ordered = [Slide(start: 0, headlineHTML: "See it in action", subHTML: "")]
        }
        ordered[0].start = 0

        // Collapse consecutive duplicates and enforce strictly increasing starts
        // (zero-length segments would break the composition's instruction tiling).
        var deduped: [Slide] = []
        for slide in ordered {
            if let last = deduped.last {
                if last.headlineHTML == slide.headlineHTML && last.subHTML == slide.subHTML { continue }
                if slide.start <= last.start + 0.05 { continue }
            }
            deduped.append(slide)
        }

        var rendered: [String: CGImage] = [:]
        var segments: [Segment] = []
        for (index, slide) in deduped.enumerated() {
            progress?(index + 1, deduped.count)
            let key = slide.headlineHTML + "\u{1}" + slide.subHTML
            if let cached = rendered[key] {
                segments.append(Segment(start: slide.start, background: cached))
                continue
            }
            let html = layout.templateHTML(headlineHTML: slide.headlineHTML, subHTML: slide.subHTML, theme: theme)
            let image = try await renderer.render(html: html, pixelWidth: width, pixelHeight: height)
            guard let cg = Exporters.cgImage(from: image, pixelWidth: width, pixelHeight: height) else {
                throw StudioError("Could not rasterize the video frame background.")
            }
            rendered[key] = cg
            segments.append(Segment(start: slide.start, background: cg))
        }

        return VideoFraming(
            segments: segments,
            canvas: VideoFrameLayout.canvas,
            screenRect: layout.screenRect,
            screenRadius: layout.screenRadius
        )
    }

    /// Screen rect in Core Image (bottom-left origin) coordinates.
    var screenRectCI: CGRect {
        CGRect(
            x: screenRect.minX,
            y: canvas.height - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    /// Full-canvas RGBA mask: opaque white rounded rect at the screen, fully
    /// transparent elsewhere — the alpha channel drives `CIBlendWithMask`.
    /// Built in Core Image (bottom-left) space to match the compositor.
    func roundedScreenMask() -> CGImage? {
        let width = Int(canvas.width), height = Int(canvas.height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGPath(roundedRect: screenRectCI, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fillPath()
        return ctx.makeImage()
    }
}
