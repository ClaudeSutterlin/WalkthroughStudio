import Foundation
import WebKit
import AppKit

/// Renders a `.mmd` diagram to SVG with the bundled Mermaid (D16), offscreen.
///
/// The `.mmd` files carry no theme directive on purpose — they stay portable, so a user
/// can paste one into any Mermaid tool — and the brand tokens are applied here, at
/// render time, exactly as the hub applies them in the browser. A theme directive
/// inside the file made Mermaid mark the element processed and emit no SVG at all.
///
/// `mermaid.render()` rather than `mermaid.run()`: run races its own startOnLoad pass
/// and can mark an element processed without producing anything.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loaded: CheckedContinuation<Void, Error>?

    /// Seconds to wait for Mermaid before giving up. A diagram that does not render is
    /// a notice on the package, never a failed build.
    static let timeout: TimeInterval = 20

    func render(mermaid source: String, theme: BrandTheme) async throws -> String {
        guard let libraryURL = Bundle.module.url(forResource: "mermaid.min",
                                                 withExtension: "js",
                                                 subdirectory: "OnboardingResources/hub/vendor"),
              let library = try? String(contentsOf: libraryURL, encoding: .utf8) else {
            throw StudioError("MermaidRenderer: the bundled mermaid.min.js is missing.")
        }

        let page = MermaidRenderer.page(library: library, source: source, theme: theme)
        let frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        self.webView = webView

        // WebKit does not paint — and here, does not run layout-dependent code — unless
        // the view is in a window (CLAUDE.md landmine 2).
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000,
                                                  width: frame.width, height: frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.orderBack(nil)
        self.window = window
        defer {
            window.orderOut(nil)
            window.contentView = nil
            self.webView = nil
            self.window = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loaded = continuation
            webView.loadHTMLString(page, baseURL: nil)
        }

        let deadline = Date().addingTimeInterval(MermaidRenderer.timeout)
        while Date() < deadline {
            if let result = try? await webView.evaluateJavaScript("window.__result || null"),
               let object = result as? [String: Any] {
                if let svg = object["svg"] as? String, !svg.isEmpty { return svg }
                if let error = object["error"] as? String {
                    throw StudioError("MermaidRenderer: \(error)")
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw StudioError("MermaidRenderer: the diagram did not render within "
                          + "\(Int(MermaidRenderer.timeout))s.")
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loaded?.resume()
            self.loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.loaded?.resume(throwing: error)
            self.loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.loaded?.resume(throwing: error)
            self.loaded = nil
        }
    }

    /// The same initialize call the hub makes, so a diagram looks identical in a video
    /// and in the browser.
    static func page(library: String, source: String, theme: BrandTheme) -> String {
        let escaped = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { margin: 0; background: \(theme.backgroundColor); }
        </style></head><body><div id="host"></div>
        <script>\(library)</script>
        <script>
        (async () => {
          try {
            window.mermaid.initialize({
              startOnLoad: false, securityLevel: "loose", theme: "base",
              themeVariables: {
                primaryColor: "#FFFBF5", primaryTextColor: "\(theme.headlineColor)",
                primaryBorderColor: "\(theme.headlineColor)", lineColor: "\(theme.headlineColor)",
                secondaryColor: "#F2E8DC", tertiaryColor: "#FFFBF5",
                fontFamily: \(MermaidRenderer.jsString(theme.headlineFontCSS)), fontSize: "15px",
                noteBkgColor: "#F2E8DC", noteTextColor: "\(theme.headlineColor)",
                noteBorderColor: "#E3D5C3", actorBkg: "#FFFBF5",
                actorBorder: "\(theme.headlineColor)", actorTextColor: "\(theme.headlineColor)",
                signalColor: "\(theme.headlineColor)", signalTextColor: "\(theme.headlineColor)"
              }
            });
            const { svg } = await window.mermaid.render("m" + Date.now(), `\(escaped)`);
            window.__result = { svg };
          } catch (e) {
            window.__result = { error: String((e && e.message) || e) };
          }
        })();
        </script></body></html>
        """
    }

    static func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Adds `class="focus"` to the groups a shot's nodes drew, which is what the
    /// diagram scene's CSS styles. Done on the SVG text rather than in Mermaid, because
    /// Mermaid has no idea which boxes this shot is about.
    ///
    /// Mermaid names its groups differently per diagram type — `flowchart-<node>-3`,
    /// `entity-<NODE>-<uuid>`, `root-2` — so matching is by hyphen-delimited token
    /// rather than by one prefix. Our own node ids never contain a hyphen
    /// (`ProjectionSupport.mermaidID` emits underscores), so the split is unambiguous.
    /// Checked against every node of every fixture diagram: 28 of 28 match.
    static func focus(_ svg: String, nodes: [String]) -> String {
        let wanted = Set(nodes.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return svg }

        var out = ""
        var rest = Substring(svg)
        var focused = 0
        while let open = rest.range(of: "<g ") {
            out += rest[rest.startIndex..<open.lowerBound]
            // The group's own attributes end at the first `>`.
            guard let close = rest[open.upperBound...].firstIndex(of: ">") else {
                out += rest[open.lowerBound...]
                return out
            }
            let attributes = rest[open.upperBound..<close]
            if let id = MermaidRenderer.attribute("id", in: String(attributes)),
               MermaidRenderer.identifies(id, oneOf: wanted) {
                out += "<g class=\"focus\" " + attributes + ">"
                focused += 1
            } else {
                out += "<g " + attributes + ">"
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return focused > 0 ? out : svg
    }

    /// True when `id` is, or is built from, one of the node ids.
    static func identifies(_ id: String, oneOf nodes: Set<String>) -> Bool {
        if nodes.contains(id) { return true }
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return false }
        return parts.dropFirst().contains { nodes.contains($0) }
    }

    /// `name="value"` out of an attribute string, without parsing XML for it.
    ///
    /// The leading space matters: searching for `id="` alone would also find
    /// `markerId="` and `data-id="`, and focus the wrong group.
    static func attribute(_ name: String, in attributes: String) -> String? {
        let padded = " " + attributes
        guard let start = padded.range(of: " \(name)=\"") else { return nil }
        let attributes = padded
        guard let end = attributes[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(attributes[start.upperBound..<end])
    }
}
