import SwiftUI
import WebKit

/// The centre pane: the package's own hub, rendered in a `WKWebView` (D20).
///
/// The same `hub.html`/`hub.js`/`hub.css` the static export ships, loaded over
/// `walkthrough://package/` so `fetch()` works. Building native `DocView`,
/// `DiagramView` and `CodeView` beside it would mean two renderers for three surfaces,
/// forever, diverging quietly — and the export needs the HTML one regardless.
///
/// The bridge is deliberately two small messages wide: the app asks the hub to route,
/// the hub tells the app where it went and hands back anything the app owns (a video).
struct HubWebView: NSViewRepresentable {

    @ObservedObject var vm: OnboardingViewModel
    /// The package to serve. Changing it rebuilds the web view, because a
    /// `WKURLSchemeHandler` is bound to a configuration and cannot be swapped.
    let packageRoot: URL

    func makeCoordinator() -> Coordinator { Coordinator(vm: vm) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            WalkthroughSchemeHandler(root: packageRoot, overlay: HubWebView.viewerOverlay()),
            forURLScheme: WalkthroughSchemeHandler.scheme)
        // Injected before the document runs, so `hub.js` sees it at its first line.
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.walkthroughEmbedded = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "walkthrough")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.load(URLRequest(url: WalkthroughSchemeHandler.url(forRelativePath: "hub.html")))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.vm = vm
        guard let anchor = vm.pendingAnchor, anchor != context.coordinator.lastRequested else { return }
        context.coordinator.lastRequested = anchor
        context.coordinator.route(anchor)
    }

    /// The viewer's own files live in the app bundle, not in the package — a package
    /// produced by an older build still renders with this build's hub. A package that
    /// ships its own copy (the static export does) keeps it, because the handler
    /// prefers the package when the file is there.
    static func viewerOverlay() -> [String: URL] {
        var overlay: [String: URL] = [:]
        for name in ["hub.html", "hub.css", "hub.js", "vendor/mermaid.min.js"] {
            let parts = name.split(separator: "/").map(String.init)
            let subdirectory = (["OnboardingResources", "hub"] + parts.dropLast()).joined(separator: "/")
            if let url = Bundle.module.url(forResource: parts[parts.count - 1], withExtension: nil,
                                           subdirectory: subdirectory) {
                overlay[name] = url
            }
        }
        return overlay
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var vm: OnboardingViewModel
        weak var webView: WKWebView?
        var lastRequested: String?
        /// Anchors asked for before the hub finished loading; replayed on `loaded`.
        private var queued: [String] = []
        private var isReady = false

        init(vm: OnboardingViewModel) {
            self.vm = vm
        }

        func route(_ anchor: String) {
            guard isReady else {
                queued = [anchor]      // only the last one matters
                return
            }
            let escaped = anchor.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView?.evaluateJavaScript("window.walkthroughHub.route('\(escaped)')")
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let kind = body["kind"] as? String else { return }
            let viewModel = vm
            switch kind {
            case "loaded":
                isReady = true
                let replay = queued
                queued = []
                for anchor in replay { route(anchor) }
            case "navigated":
                let anchor = body["anchor"] as? String ?? ""
                let title = body["title"] as? String ?? ""
                let canGoBack = body["canGoBack"] as? Bool ?? false
                Task { @MainActor in
                    viewModel.hubDidNavigate(anchor: anchor, title: title, canGoBack: canGoBack)
                }
            case "open":
                // Something the app owns — today only `video:`.
                guard let anchor = body["anchor"] as? String else { return }
                Task { @MainActor in viewModel.open(anchor: anchor) }
            default:
                break
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let viewModel = vm
            Task { @MainActor in viewModel.note("The package viewer did not load", error) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let viewModel = vm
            Task { @MainActor in viewModel.note("The package viewer did not load", error) }
        }
    }
}
