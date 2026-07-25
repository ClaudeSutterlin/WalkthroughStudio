import Foundation
import AppKit
import WebKit

// MARK: - Viewport presets

/// Which browser identity a web capture uses. Drives the recorded pixel size,
/// the CSS viewport (via `pageZoom`), the user agent, and the project's
/// resulting `DeviceKind`.
enum CaptureViewport: String, CaseIterable, Identifiable {
    case desktop
    case iphone

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop: return "Desktop browser"
        case .iphone: return "iPhone"
        }
    }

    /// Recorded video size in pixels (kept even for H.264). The iPhone preset
    /// records at a real device resolution so App Store exports stay crisp.
    var pixelSize: CGSize {
        switch self {
        case .desktop: return CGSize(width: 2560, height: 1600)
        case .iphone: return CGSize(width: 1170, height: 2532) // iPhone 14
        }
    }

    /// Content renders at `pageZoom`× the CSS viewport so text stays crisp in
    /// the video (2× desktop, 3× phone — matching real device pixel ratios).
    var pageZoom: CGFloat {
        switch self {
        case .desktop: return 2
        case .iphone: return 3
        }
    }

    /// iPhone captures reserve a top band where the recorder paints the
    /// Apple-marketing status bar (9:41, Dynamic Island) — so the recording
    /// reads as a phone screen, matching imported iPhone recordings.
    var statusBarBandHeight: Int {
        switch self {
        case .desktop: return 0
        case .iphone: return 174 // ≈ height × DeviceKind.iphone.statusBarFraction; content stays ÷3 clean
        }
    }

    /// The web page's area of the recorded frame (below the status-bar band).
    var contentPixelSize: CGSize {
        CGSize(width: pixelSize.width, height: pixelSize.height - CGFloat(statusBarBandHeight))
    }

    /// Mobile sites need a mobile UA; desktop uses WebKit's default.
    var userAgent: String? {
        switch self {
        case .desktop:
            return nil
        case .iphone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        }
    }

    var deviceKind: DeviceKind {
        switch self {
        case .desktop: return .computer
        case .iphone: return .iphone
        }
    }
}

// MARK: - Session

/// Drives a live web page for the capture agent: loads URLs, inventories the
/// interactable elements (injected JS), clicks/types/scrolls, and takes
/// pixel-exact snapshots. The WKWebView is hosted in an offscreen NSWindow —
/// WebKit doesn't paint otherwise (see BrandedRenderer).
///
/// Coordinates: element frames and click points are returned in CONTENT
/// PIXELS with a top-left origin — CSS coordinates × `pageZoom`, matching the
/// snapshot image exactly. The recorder adds the status-bar band offset.
@MainActor
final class WebCaptureSession: NSObject, WKNavigationDelegate, WKUIDelegate {

    /// One interactable element from the last `inventory()` call. Indices are
    /// only valid against that inventory (the page holds the element list).
    struct Element {
        var index: Int
        var tag: String
        var role: String
        var label: String
        var frame: CGRect     // content pixels, top-left origin
        var editable: Bool
    }

    let viewport: CaptureViewport
    private let webView: WKWebView
    private let window: NSWindow
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var navigationsInFlight = 0

    init(viewport: CaptureViewport) {
        self.viewport = viewport
        let content = viewport.contentPixelSize
        let frame = NSRect(x: 0, y: 0, width: content.width, height: content.height)

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let view = WKWebView(frame: frame, configuration: configuration)
        view.pageZoom = viewport.pageZoom
        if let ua = viewport.userAgent { view.customUserAgent = ua }

        let host = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: frame.width, height: frame.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentView = view
        host.orderBack(nil)

        webView = view
        window = host
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    // MARK: Navigation

    func load(url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.loadContinuation = continuation
            if url.isFileURL {
                // Local pages (the selftest fixture) need explicit read access,
                // directory-wide so relative navigation between pages works.
                self.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                self.webView.load(URLRequest(url: url, timeoutInterval: 30))
            }
        }
        await settle(timeout: 4)
    }

    /// Wait for any in-flight navigation to finish and the page to settle.
    /// SPAs never "navigate", so there's always a minimum breather.
    func settle(timeout: Double) async {
        let start = Date()
        // Give a click a beat to actually start a navigation before checking.
        try? await Task.sleep(nanoseconds: 350_000_000)
        while Date().timeIntervalSince(start) < timeout {
            if navigationsInFlight == 0 {
                let ready = (try? await evaluate("document.readyState")) as? String
                if ready == "complete" || ready == "interactive" { break }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        // Rendering catch-up (images, fonts, transition animations).
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    var currentURLString: String {
        webView.url?.absoluteString ?? ""
    }

    func pageTitle() async -> String {
        ((try? await evaluate("document.title")) as? String) ?? ""
    }

    // MARK: Snapshots

    /// Pixel-exact image of the page content (the area below the status-bar
    /// band in the recorded frame).
    func snapshot() async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? StudioError("Page snapshot failed."))
                }
            }
        }
        let size = viewport.contentPixelSize
        guard let cg = Exporters.cgImage(from: image, pixelWidth: Int(size.width), pixelHeight: Int(size.height)) else {
            throw StudioError("Could not rasterize the page snapshot.")
        }
        return cg
    }

    // MARK: JavaScript plumbing

    @discardableResult
    func evaluate(_ script: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

    /// JSON-encode a value for safe inline embedding in a JS call.
    private static func jsLiteral(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let wrapped = String(data: data, encoding: .utf8) else { return "null" }
        return String(wrapped.dropFirst().dropLast()) // strip the [ ] wrapper
    }

    // MARK: Element inventory

    /// Enumerate the visible interactable elements (links, buttons, inputs,
    /// ARIA widgets) currently in the viewport. The page keeps the element
    /// references (`window.__wsElements`) so later clicks resolve by index.
    func inventory() async throws -> [Element] {
        let script = """
        (function() {
          const vw = innerWidth, vh = innerHeight;
          const nodes = Array.from(document.querySelectorAll(
            'a,button,input,textarea,select,summary,[role],[onclick],[contenteditable=""],[contenteditable="true"]'
          ));
          const out = [], els = [];
          const interactiveRoles = ['button','link','tab','menuitem','checkbox','radio','switch','option','combobox','searchbox','textbox','slider'];
          for (const el of nodes) {
            if (out.length >= 120) break;
            const r = el.getBoundingClientRect();
            if (r.width < 4 || r.height < 4) continue;
            if (r.bottom < 0 || r.top > vh || r.right < 0 || r.left > vw) continue;
            const cs = getComputedStyle(el);
            if (cs.visibility === 'hidden' || cs.display === 'none' || parseFloat(cs.opacity) < 0.05) continue;
            const tag = el.tagName.toLowerCase();
            const role = (el.getAttribute('role') || '').toLowerCase();
            const nativeTags = ['a','button','input','textarea','select','summary'];
            if (!nativeTags.includes(tag) && !interactiveRoles.includes(role)
                && !el.hasAttribute('onclick') && !el.isContentEditable) continue;
            let label = (el.getAttribute('aria-label') || el.placeholder || el.value || el.innerText
                         || el.title || el.getAttribute('name') || '');
            label = String(label).trim().replace(/\\s+/g, ' ').slice(0, 90);
            const type = (el.type || '').toLowerCase();
            const editable = tag === 'textarea' || el.isContentEditable
              || (tag === 'input' && !['button','submit','checkbox','radio','range','file','image','reset','color','hidden'].includes(type || 'text'));
            out.push({
              i: els.length, tag: tag, role: role, label: label,
              x: r.left, y: r.top, w: r.width, h: r.height,
              editable: !!editable
            });
            els.push(el);
          }
          window.__wsElements = els;
          return JSON.stringify(out);
        })()
        """
        guard let json = try await evaluate(script) as? String,
              let data = json.data(using: .utf8),
              let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw StudioError("The page's element inventory could not be read.")
        }
        let zoom = viewport.pageZoom
        return items.compactMap { item in
            guard let index = item["i"] as? Int else { return nil }
            let x = (item["x"] as? Double ?? 0) * zoom
            let y = (item["y"] as? Double ?? 0) * zoom
            let w = (item["w"] as? Double ?? 0) * zoom
            let h = (item["h"] as? Double ?? 0) * zoom
            return Element(
                index: index,
                tag: item["tag"] as? String ?? "",
                role: item["role"] as? String ?? "",
                label: item["label"] as? String ?? "",
                frame: CGRect(x: x, y: y, width: w, height: h),
                editable: item["editable"] as? Bool ?? false
            )
        }
    }

    // MARK: Actions

    /// Scroll the element into view and return its center in content pixels —
    /// where the cursor should travel BEFORE `commitClick` fires the events.
    func prepareClick(elementIndex: Int) async throws -> CGPoint {
        let script = """
        (function(i) {
          const el = window.__wsElements && window.__wsElements[i];
          if (!el) return null;
          el.scrollIntoView({block: 'center', inline: 'nearest', behavior: 'instant'});
          const r = el.getBoundingClientRect();
          return JSON.stringify({x: r.left + r.width / 2, y: r.top + r.height / 2});
        })(\(elementIndex))
        """
        guard let json = try await evaluate(script) as? String,
              let data = json.data(using: .utf8),
              let point = (try? JSONSerialization.jsonObject(with: data)) as? [String: Double],
              let x = point["x"], let y = point["y"] else {
            throw StudioError("Element \(elementIndex) is gone — the page changed since it was inventoried.")
        }
        return CGPoint(x: x * viewport.pageZoom, y: y * viewport.pageZoom)
    }

    /// Fire the full pointer/mouse event sequence (plus `.click()`) on the
    /// element. Navigation, if any, is awaited by the caller via `settle`.
    func commitClick(elementIndex: Int) async throws {
        let script = """
        (function(i) {
          const el = window.__wsElements && window.__wsElements[i];
          if (!el) return false;
          const r = el.getBoundingClientRect();
          const opts = {bubbles: true, cancelable: true, view: window,
                        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0};
          for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup']) {
            try {
              el.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, opts) : new MouseEvent(type, opts));
            } catch (e) {
              el.dispatchEvent(new MouseEvent(type.replace('pointer', 'mouse'), opts));
            }
          }
          if (typeof el.click === 'function') el.click();
          if (typeof el.focus === 'function') el.focus();
          return true;
        })(\(elementIndex))
        """
        guard (try await evaluate(script) as? Bool) == true else {
            throw StudioError("Element \(elementIndex) is gone — the page changed since it was inventoried.")
        }
    }

    /// Set a field's value (React-safe: native setter + input/change events).
    /// The driver calls this with growing prefixes to animate typing.
    func setText(elementIndex: Int, text: String) async throws {
        let script = """
        (function(i, text) {
          const el = window.__wsElements && window.__wsElements[i];
          if (!el) return false;
          if (typeof el.focus === 'function') el.focus();
          if (el.isContentEditable) {
            el.textContent = text;
          } else {
            const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
            if (descriptor && descriptor.set) { descriptor.set.call(el, text); } else { el.value = text; }
          }
          el.dispatchEvent(new Event('input', {bubbles: true}));
          el.dispatchEvent(new Event('change', {bubbles: true}));
          return true;
        })(\(elementIndex), \(Self.jsLiteral(text)))
        """
        guard (try await evaluate(script) as? Bool) == true else {
            throw StudioError("Element \(elementIndex) is gone — the page changed since it was inventoried.")
        }
    }

    /// Scroll the page by `dy` content pixels. Returns how far it actually
    /// moved (0 at the bottom), in content pixels.
    @discardableResult
    func scroll(byPixels dy: CGFloat) async throws -> CGFloat {
        let css = dy / viewport.pageZoom
        let script = """
        (function(dy) {
          const before = scrollY;
          window.scrollBy({top: dy, behavior: 'instant'});
          return scrollY - before;
        })(\(css))
        """
        let moved = (try await evaluate(script) as? Double) ?? 0
        return CGFloat(moved) * viewport.pageZoom
    }

    // MARK: WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The agent stays inside the browser: no mailto/tel/app-store handoffs.
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "data", "blob", "file"].contains(scheme) ? .allow : .cancel)
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // A download (PDF, zip, …) would leave the load waiting forever;
        // cancelling turns it into a provisional failure the caller sees.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in self.navigationsInFlight += 1 }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationsInFlight = max(0, self.navigationsInFlight - 1)
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.navigationsInFlight = max(0, self.navigationsInFlight - 1)
            self.loadContinuation?.resume(throwing: error)
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.navigationsInFlight = max(0, self.navigationsInFlight - 1)
            // Mid-session provisional failures (e.g. a cancelled subresource
            // navigation) shouldn't kill anything unless a load() is waiting.
            self.loadContinuation?.resume(throwing: error)
            self.loadContinuation = nil
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: StudioError("The capture browser's web process quit — try the capture again."))
            self.loadContinuation = nil
        }
    }

    // MARK: WKUIDelegate

    /// target=_blank links open in the SAME view — the capture has one tab.
    nonisolated func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        Task { @MainActor in
            if let url = navigationAction.request.url {
                self.webView.load(URLRequest(url: url))
            }
        }
        return nil
    }

    /// Dismiss JS dialogs so a stray alert can never hang a headless capture.
    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(defaultText)
    }
}
