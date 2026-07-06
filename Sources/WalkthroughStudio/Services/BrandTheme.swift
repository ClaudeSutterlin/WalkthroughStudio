import Foundation
import SwiftUI
import AppKit

/// Editable design tokens for the branded frames (App Store slides + the 16:9
/// video wrapper). The frames are plain HTML/CSS; the theme is injected as a
/// CSS override block via the {{THEME_CSS}} placeholder, so it works with both
/// the bundled templates and user-customized ones (as long as they keep the
/// placeholder and class names).
struct BrandTheme: Codable, Equatable, Hashable {
    private enum CodingKeys: String, CodingKey {
        case headlineColor, accentColor, subColor, headlineFontCSS
        case backgroundMode, backgroundColor, backgroundImagePath
        case bezelColor, showWordmark, wordmarkText, logoImagePath
        case statusBarMode
        case hideStatusBar // legacy (pre-mode boolean)
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BrandTheme()
        headlineColor = try c.decodeIfPresent(String.self, forKey: .headlineColor) ?? d.headlineColor
        accentColor = try c.decodeIfPresent(String.self, forKey: .accentColor) ?? d.accentColor
        subColor = try c.decodeIfPresent(String.self, forKey: .subColor) ?? d.subColor
        headlineFontCSS = try c.decodeIfPresent(String.self, forKey: .headlineFontCSS) ?? d.headlineFontCSS
        backgroundMode = try c.decodeIfPresent(String.self, forKey: .backgroundMode) ?? d.backgroundMode
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor) ?? d.backgroundColor
        backgroundImagePath = try c.decodeIfPresent(String.self, forKey: .backgroundImagePath) ?? d.backgroundImagePath
        bezelColor = try c.decodeIfPresent(String.self, forKey: .bezelColor) ?? d.bezelColor
        showWordmark = try c.decodeIfPresent(Bool.self, forKey: .showWordmark) ?? d.showWordmark
        wordmarkText = try c.decodeIfPresent(String.self, forKey: .wordmarkText) ?? d.wordmarkText
        logoImagePath = try c.decodeIfPresent(String.self, forKey: .logoImagePath) ?? d.logoImagePath
        if let mode = try c.decodeIfPresent(String.self, forKey: .statusBarMode) {
            statusBarMode = mode
        } else if let legacy = try c.decodeIfPresent(Bool.self, forKey: .hideStatusBar) {
            statusBarMode = legacy ? "crop" : "off"
        }
    }

    // Explicit encode: the legacy `hideStatusBar` key is decode-only, which
    // disables synthesized Encodable.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(headlineColor, forKey: .headlineColor)
        try c.encode(accentColor, forKey: .accentColor)
        try c.encode(subColor, forKey: .subColor)
        try c.encode(headlineFontCSS, forKey: .headlineFontCSS)
        try c.encode(backgroundMode, forKey: .backgroundMode)
        try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(backgroundImagePath, forKey: .backgroundImagePath)
        try c.encode(bezelColor, forKey: .bezelColor)
        try c.encode(showWordmark, forKey: .showWordmark)
        try c.encode(wordmarkText, forKey: .wordmarkText)
        try c.encode(logoImagePath, forKey: .logoImagePath)
        try c.encode(statusBarMode, forKey: .statusBarMode)
    }

    var headlineColor = "#1A1612"
    var accentColor = "#DA4F45"
    var subColor = "#5C5549"
    var headlineFontCSS = "Georgia, 'Times New Roman', serif"

    /// "brand" (the default warm gradient), "color", or "image"
    var backgroundMode = "brand"
    var backgroundColor = "#FFFBF5"
    var backgroundImagePath = ""

    var bezelColor = "#1A1612"

    var showWordmark = true
    var wordmarkText = "Your App"
    var logoImagePath = ""

    /// What to do about the recording's status bar (clock, battery, the red
    /// screen-recording indicator):
    /// - "clean" (default): keep the layout, replace the bar with a pristine
    ///   9:41 / full-signal / full-battery one (Apple's own convention).
    /// - "crop": cut the band off entirely (changes the visible aspect).
    /// - "off": ship frames exactly as recorded.
    var statusBarMode = "clean"

    /// ≈ a modern iPhone status bar (59pt of an 852pt screen).
    static let statusBarCropFraction: Double = 0.0693

    var isDefault: Bool { self == BrandTheme() }

    /// The wordmark text, HTML-escaped for the template.
    var wordmarkHTML: String {
        wordmarkText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// CSS override block appended at the end of the template's <style>, so
    /// these rules win over the defaults without needing !important.
    func css() -> String {
        guard !isDefault else { return "" }
        var rules: [String] = []
        rules.append(".headline { color: \(headlineColor); font-family: \(headlineFontCSS); }")
        rules.append(".headline .accent { color: \(accentColor); }")
        rules.append(".sub { color: \(subColor); }")
        rules.append(".phone { background: \(bezelColor); }")
        rules.append(".wordmark .name { color: \(headlineColor); }")
        rules.append(".wordmark .icon { background: \(accentColor); }")

        switch backgroundMode {
        case "color":
            rules.append(".slide, .stage { background: \(backgroundColor); }")
            rules.append(".orb { display: none; }")
        case "image":
            if let dataURL = Self.imageDataURL(backgroundImagePath) {
                rules.append(".slide, .stage { background: url('\(dataURL)') center / cover no-repeat; }")
                rules.append(".orb { display: none; }")
            }
        default:
            break
        }

        if !showWordmark {
            rules.append(".wordmark { display: none; }")
        } else if !logoImagePath.isEmpty, let dataURL = Self.imageDataURL(logoImagePath) {
            rules.append(".wordmark .icon svg { display: none; }")
            rules.append(".wordmark .icon { background: transparent url('\(dataURL)') center / contain no-repeat; border-radius: 0; }")
        }
        return rules.joined(separator: "\n")
    }

    /// Re-encode any readable image as a PNG data URL (keeps HTML self-contained).
    static func imageDataURL(_ path: String) -> String? {
        guard !path.isEmpty, let image = NSImage(contentsOfFile: path) else { return nil }
        let size = image.size
        let maxDim: CGFloat = 2400
        let scale = min(1, maxDim / max(size.width, size.height, 1))
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let png = Exporters.pngData(from: image, pixelWidth: width, pixelHeight: height) else { return nil }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }
}

// MARK: - Hex <-> Color bridging for the editor

extension Color {
    init(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "#%02X%02X%02X",
            Int(round(ns.redComponent * 255)),
            Int(round(ns.greenComponent * 255)),
            Int(round(ns.blueComponent * 255))
        )
    }
}

// MARK: - Template store (bundled defaults, user overrides on disk)

/// Loads frame templates, preferring user-edited copies in Application Support
/// over the bundled defaults — the escape hatch for full HTML/CSS redesigns.
enum TemplateStore {
    static let templateNames = ["slide-template", "video-frame-template"]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Walkthrough Studio/Templates", isDirectory: true)
    }

    /// Custom template if the user has one, otherwise the bundled default.
    static func load(_ name: String) -> String? {
        let custom = directory.appendingPathComponent("\(name).html")
        if let text = try? String(contentsOf: custom, encoding: .utf8) {
            return text
        }
        guard let bundled = Bundle.module.url(forResource: name, withExtension: "html") else { return nil }
        return try? String(contentsOf: bundled, encoding: .utf8)
    }

    /// Copy the bundled templates (if not already customized) plus the
    /// Claude Code guide into the editing folder, and return it.
    @discardableResult
    static func materializeForEditing() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in templateNames {
            let destination = directory.appendingPathComponent("\(name).html")
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let bundled = Bundle.module.url(forResource: name, withExtension: "html") else { continue }
            try FileManager.default.copyItem(at: bundled, to: destination)
        }
        try customizingGuide.write(
            to: directory.appendingPathComponent("CUSTOMIZING.md"),
            atomically: true, encoding: .utf8
        )
        return directory
    }

    static let customizingGuide = """
    # Customizing the Walkthrough Studio frames

    The branded frames are plain HTML + CSS. Walkthrough Studio loads the two
    templates in this folder **instead of its built-in ones** whenever they
    exist here — edit, save, and the very next preview or export uses your
    version. To go back to the defaults, delete the file (the app falls back
    to its bundled copy).

    ## The two templates

    | File | Used for | Canvas |
    |---|---|---|
    | `slide-template.html` | App Store screenshots (portrait) | `{{WIDTH}}x{{HEIGHT}}` — 1290x2796 and 1284x2778 |
    | `video-frame-template.html` | The 16:9 framed video export | `{{WIDTH}}x{{HEIGHT}}` — 1920x1080 |

    ## The contract — keep these placeholders

    The app fills these slots before rendering; everything else is yours.

    Both templates:
    - `{{WIDTH}}` / `{{HEIGHT}}` — canvas size in px. Always derive your layout
      from these (they vary between export sizes), never hard-code dimensions.
    - `{{HEADLINE}}` — title text slot (may contain `<br>` and
      `<span class="accent">…</span>`).
    - `{{SUB}}` — subtitle text slot.
    - `{{THEME_CSS}}` — where the in-app design editor injects its overrides
      (colors, background, logo). Keep it at the end of your `<style>` block,
      or remove it if you want your CSS to be the only authority.
    - `{{WORDMARK}}` — the wordmark name text.

    `slide-template.html` only:
    - `{{SCREEN_BLOCK}}` — the screenshot slot. It becomes an `<img>` with
      `object-fit: cover` inside your `.screen` element. Put it wherever the
      screenshot should appear.
    - `{{DEVICE_W}} {{DEVICE_R}} {{DEVICE_PAD}} {{SCREEN_R}} {{SCREEN_AR}}` —
      device bezel geometry and the screen's aspect ratio, computed by the app
      from the project's device kind (iPhone/iPad) and the actual recording
      dimensions. Keep them so one template serves every device.

    `video-frame-template.html` only:
    - `{{PHONE_LEFT}} {{PHONE_TOP}} {{PHONE_W}} {{PHONE_H}} {{PAD}} {{BEZEL_R}}
      {{SCREEN_R}} {{TEXT_LEFT}} {{TEXT_TOP}} {{TEXT_W}} {{TEXT_ALIGN}}` —
      device and text geometry, computed by the app. Portrait recordings get a
      side-by-side layout (text left, device right); landscape recordings
      (iPad landscape, computer) get a stacked one (centered text banner on
      top, wide device below). **Important:** the app composites the
      actual video into the device screen rectangle at exactly the position
      given by these values — restyle anything you like, but the `.phone`
      element must stay positioned by these placeholders or the video will
      land in the wrong place.

    ## Theme editor interplay

    The in-app editor (Project ▸ Customize Frame Design…) works by writing CSS
    against these class names: `.headline`, `.headline .accent`, `.sub`,
    `.phone`, `.wordmark`, `.wordmark .icon`, `.wordmark .name`, `.slide`,
    `.stage`, `.orb`. Keep those names if you want the editor to keep working
    with your custom template; rename them and the editor's changes will
    simply have no effect.

    ## Using Claude Code to redesign

    Open a terminal in this folder and run `claude`, then describe what you
    want. Examples that work well:

    - "Restyle slide-template.html with a deep navy background, white headline,
      and an electric-blue accent. Keep every {{PLACEHOLDER}} exactly where the
      contract needs it."
    - "In video-frame-template.html, move the text column to the right and the
      device to the left, keeping the .phone element positioned by the
      PHONE_* placeholders."
    - "Add a subtle grid pattern behind everything on both templates."

    Tell Claude about the contract above (or just point it at this file). The
    app re-reads templates on every render, so you can iterate live: save in
    Claude Code → re-export or reopen the preview in Walkthrough Studio.
    """
}
