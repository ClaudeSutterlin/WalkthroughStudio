import Foundation
import AppKit
import WebKit

/// Builds slide HTML from the bundled template (the verbatim CSS from the
/// existing web pipeline) and rasterizes it offscreen with WKWebView +
/// takeSnapshot — the spec's "fastest / exact parity" option.
enum SlideTemplate {
    /// Device bezel proportions for the slide, derived from the canvas width.
    struct DeviceGeometry {
        var width: CGFloat
        var radius: CGFloat
        var pad: CGFloat
        var screenRadius: CGFloat
        var aspectCSS: String

        static func forDevice(_ kind: DeviceKind, canvasWidth: CGFloat, videoSize: CGSize?) -> DeviceGeometry {
            let aspect: String
            if let videoSize, videoSize.width > 0, videoSize.height > 0 {
                aspect = "\(Int(videoSize.width)) / \(Int(videoSize.height))"
            } else {
                aspect = kind == .ipad ? "3 / 4" : "1206 / 2622"
            }
            switch kind {
            case .iphone:
                let w = canvasWidth * 0.721
                return DeviceGeometry(width: w, radius: w * 0.0957, pad: w * 0.0183, screenRadius: w * 0.0796, aspectCSS: aspect)
            case .ipad:
                let w = canvasWidth * 0.82
                return DeviceGeometry(width: w, radius: w * 0.038, pad: w * 0.024, screenRadius: w * 0.016, aspectCSS: aspect)
            case .computer:
                let w = canvasWidth * 0.86
                return DeviceGeometry(width: w, radius: w * 0.020, pad: w * 0.010, screenRadius: w * 0.012, aspectCSS: aspect)
            }
        }
    }

    static func html(
        width: Int,
        height: Int,
        headlineHTML: String,
        subHTML: String,
        screenshotDataURL: String?,
        placeholderLabel: String,
        theme: BrandTheme = BrandTheme(),
        device: DeviceKind = .iphone,
        videoSize: CGSize? = nil
    ) -> String {
        guard var html = TemplateStore.load("slide-template") else {
            return "<html><body>Template missing</body></html>"
        }
        let geometry = DeviceGeometry.forDevice(device, canvasWidth: CGFloat(width), videoSize: videoSize)
        let screenBlock: String
        if let screenshotDataURL {
            screenBlock = "<img src=\"\(screenshotDataURL)\" />"
        } else {
            screenBlock = """
            <div class="placeholder">
              <div class="label">\(placeholderLabel)</div>
              <div class="hint">No frame extracted yet</div>
            </div>
            """
        }
        html = html.replacingOccurrences(of: "{{WIDTH}}", with: String(width))
        html = html.replacingOccurrences(of: "{{HEIGHT}}", with: String(height))
        html = html.replacingOccurrences(of: "{{HEADLINE}}", with: headlineHTML)
        html = html.replacingOccurrences(of: "{{SUB}}", with: subHTML)
        html = html.replacingOccurrences(of: "{{SCREEN_BLOCK}}", with: screenBlock)
        html = html.replacingOccurrences(of: "{{THEME_CSS}}", with: theme.css())
        html = html.replacingOccurrences(of: "{{WORDMARK}}", with: theme.wordmarkHTML)
        html = html.replacingOccurrences(of: "{{DEVICE_W}}", with: String(format: "%.1f", geometry.width))
        html = html.replacingOccurrences(of: "{{DEVICE_R}}", with: String(format: "%.1f", geometry.radius))
        html = html.replacingOccurrences(of: "{{DEVICE_PAD}}", with: String(format: "%.1f", geometry.pad))
        html = html.replacingOccurrences(of: "{{SCREEN_R}}", with: String(format: "%.1f", geometry.screenRadius))
        html = html.replacingOccurrences(of: "{{SCREEN_AR}}", with: geometry.aspectCSS)
        return html
    }
}

@MainActor
final class BrandedRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Render `html` at exactly `pixelWidth` x `pixelHeight` pixels.
    func render(html: String, pixelWidth: Int, pixelHeight: Int) async throws -> NSImage {
        let frame = NSRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView

        // Host the web view in an offscreen window so WebKit actually paints.
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: frame.width, height: frame.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
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
            self.loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        // Give the compositor a beat to settle blurs/gradients.
        try await Task.sleep(nanoseconds: 400_000_000)

        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.rect = frame
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            webView.takeSnapshot(with: snapshotConfiguration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? StudioError("Slide snapshot failed."))
                }
            }
        }
        return image
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.loadContinuation?.resume()
            self.loadContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: error)
            self.loadContinuation = nil
        }
    }

    // Without these two, a provisional load failure or a dead WebContent
    // process leaves the continuation unresumed and render() awaits forever.
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: error)
            self.loadContinuation = nil
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.loadContinuation?.resume(throwing: StudioError("The frame renderer's web process quit mid-render — try the export again."))
            self.loadContinuation = nil
        }
    }
}
