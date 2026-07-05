import SwiftUI

/// The Export tab (Output B): tutorialSteps payload preview + folder export.
struct ExportView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var payload = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                    vm.statusMessage = "Copied tutorialSteps to the clipboard — paste into src/lib/tutorialSteps.ts."
                } label: {
                    Label("Copy tutorialSteps", systemImage: "doc.on.doc")
                }

                Button {
                    vm.exportTutorial()
                } label: {
                    Label("Export Folder…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.coral)
                .help("Writes slug-named PNGs + tutorialSteps.ts + .json + walkthrough.md")

                Spacer()

                Text("\(vm.steps.filter(\.includeInTutorial).count) of \(vm.steps.count) steps included")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .disabled(vm.isBusy)
            .padding(12)

            Divider()

            ScrollView {
                Text(payload.isEmpty ? "No steps yet." : payload)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Brand.charcoal)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Brand.cream)

            Divider()

            Text("Paste the array into src/lib/tutorialSteps.ts and drop the exported PNGs into public/pilot/ in the web repo.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .onAppear { rebuild() }
        .onChange(of: vm.steps) { _, _ in rebuild() }
    }

    private func rebuild() {
        payload = Exporters.tutorialStepsTS(steps: vm.steps)
    }
}
