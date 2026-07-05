import SwiftUI
import WebKit

/// The Branded tab (Output C): live preview of the App Store slide + headline editing.
struct BrandedView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var previewHTML: String = ""
    @State private var screenshotDataURL: String?
    @State private var screenshotKey: String?

    var body: some View {
        HSplitView {
            editorPane
                .frame(minWidth: 360)
            previewPane
                .frame(minWidth: 340)
        }
        .task(id: previewKey) {
            await rebuildPreview()
        }
    }

    /// Changes whenever anything that affects the preview changes.
    private var previewKey: String {
        guard let step = vm.selectedStep else { return "none" }
        return "\(step.id)|\(step.frameTime)|\(step.headline)|\(step.subheadline)|\(step.title)|\(step.body)|theme:\(vm.theme.hashValue)|dev:\(vm.deviceKind.rawValue)"
    }

    @ViewBuilder
    private var editorPane: some View {
        if !vm.deviceKind.supportsAppStoreExport {
            ContentUnavailableView(
                "Not available for \(vm.deviceKind.label) recordings",
                systemImage: "desktopcomputer.trianglebadge.exclamationmark",
                description: Text("App Store Connect only takes iPhone and iPad screenshots. The framed 16:9 video and tutorial exports still work for this recording.")
            )
        } else if let id = vm.selectedStepID, let binding = vm.binding(for: id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("App Store slide")
                        .font(.headline)
                    Text("Headline — Georgia serif, 92px. `<br>` breaks lines; wrap a phrase in `<span class=\"accent\">…</span>` to make it coral.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: binding.headline)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                    Text("Subhead")
                        .font(.headline)
                    TextEditor(text: binding.subheadline)
                        .font(.body)
                        .frame(minHeight: 60)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

                    Toggle("Include in branded export", isOn: binding.includeInBranded)

                    Divider()

                    Text("Exports \(vm.steps.filter(\.includeInBranded).count) slides at \(ExportSize.appStore(for: vm.deviceKind).map { "\($0.width)×\($0.height) (\($0.dir))" }.joined(separator: " and ")), named 01-slug.png, 02-slug.png, …")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            vm.showThemeEditor = true
                        } label: {
                            Label("Customize Design…", systemImage: "paintpalette")
                        }
                        Button {
                            vm.exportBranded()
                        } label: {
                            Label("Export App Store Screenshots…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.coral)
                        .disabled(vm.isBusy)
                    }
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView(
                "No step selected",
                systemImage: "iphone",
                description: Text("Select a step in the sidebar to edit its slide.")
            )
        }
    }

    private var previewSize: ExportSize {
        ExportSize.appStore(for: vm.deviceKind).first
            ?? ExportSize(width: 1290, height: 2796, dir: "6.9-inch")
    }

    private var previewPane: some View {
        VStack(spacing: 6) {
            Text("Preview — \(previewSize.width)×\(previewSize.height) (\(previewSize.dir))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            SlideWebPreview(html: previewHTML, slideWidth: CGFloat(previewSize.width))
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func rebuildPreview() async {
        guard let step = vm.selectedStep else {
            previewHTML = ""
            return
        }
        // Everything that changes the underlying screenshot must be in this
        // key — the frame time and status-bar treatment, not just the step.
        // (The VM's own frameDataURL cache makes repeat fetches cheap.)
        let key = "\(step.id)|\(step.frameTime)|\(vm.theme.statusBarMode)|\(vm.deviceKind.rawValue)"
        if screenshotKey != key || screenshotDataURL == nil {
            screenshotDataURL = await vm.frameDataURL(for: step)
            screenshotKey = key
        }
        previewHTML = SlideTemplate.html(
            width: previewSize.width,
            height: previewSize.height,
            headlineHTML: step.headline.isEmpty ? step.title : step.headline,
            subHTML: step.subheadline.isEmpty ? step.body : step.subheadline,
            screenshotDataURL: screenshotDataURL,
            placeholderLabel: step.displayName,
            theme: vm.theme,
            device: vm.deviceKind,
            videoSize: vm.statusBarAdjustedVideoSize
        )
    }
}

/// Scaled-down live WKWebView preview of the slide HTML.
struct SlideWebPreview: NSViewRepresentable {
    let html: String
    let slideWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String = ""
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let zoom = max(0.05, min(1.0, webView.bounds.width / slideWidth))
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
        webView.pageZoom = zoom
    }
}
