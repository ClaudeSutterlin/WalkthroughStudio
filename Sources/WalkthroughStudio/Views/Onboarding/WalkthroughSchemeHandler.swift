import Foundation
import WebKit
import UniformTypeIdentifiers

/// Serves one onboarding package to the hub web view over `walkthrough://package/...`.
///
/// A custom scheme rather than `loadFileURL`, because the hub reads everything it shows
/// with `fetch()` and WebKit refuses a cross-origin `file://` fetch — the package would
/// load as a blank page with CORS errors in a console nobody is looking at. Over a
/// custom scheme the whole package is one origin and `fetch("docs/tech-debt.html")`
/// works exactly as it does over http in the browser demo.
///
/// The handler is also the sandbox: it only ever serves files inside the package root
/// it was given, so a crafted anchor in a deliverable cannot read the user's disk.
final class WalkthroughSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = Anchor.scheme
    static let host = "package"

    /// The package root. Everything served is resolved against it and must stay inside.
    private let root: URL
    /// Extra roots that may also be served, for the viewer's own assets (hub.js,
    /// mermaid) which live in the app bundle rather than in the package.
    private let overlay: [String: URL]

    init(root: URL, overlay: [String: URL] = [:]) {
        self.root = root.standardizedFileURL
        self.overlay = overlay
    }

    /// `walkthrough://package/hub.html`
    static func url(forRelativePath path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url ?? URL(string: "\(scheme)://\(host)/hub.html")!
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            return fail(task, reason: "no URL")
        }
        let relative = String(url.path.drop(while: { $0 == "/" }))
        guard !relative.isEmpty else {
            return fail(task, reason: "no path")
        }
        guard let file = resolve(relative) else {
            return fail(task, reason: "\(relative) is not part of this package")
        }
        guard let data = try? Data(contentsOf: file) else {
            return fail(task, reason: "\(relative) is not in the package")
        }
        let response = URLResponse(url: url, mimeType: WalkthroughSchemeHandler.mimeType(for: file),
                                   expectedContentLength: data.count, textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // Every response is delivered synchronously in `start`, so there is nothing
        // in flight to cancel.
    }

    // MARK: - Resolution

    /// The file a request names, or nil when it escapes the package. Percent-decoding
    /// happens first, so `%2e%2e%2f` cannot slip a `../` past the prefix check.
    func resolve(_ relative: String) -> URL? {
        let decoded = relative.removingPercentEncoding ?? relative
        if let overlaid = overlay[decoded] { return overlaid }
        let candidate = root.appendingPathComponent(decoded).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "text/javascript"
        case "json": return "application/json"
        case "jsonl", "mmd", "md", "srt", "vtt", "txt": return "text/plain"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "mp4", "m4v": return "video/mp4"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }

    private func fail(_ task: WKURLSchemeTask, reason: String) {
        task.didFailWithError(StudioError("walkthrough://: \(reason)"))
    }
}
