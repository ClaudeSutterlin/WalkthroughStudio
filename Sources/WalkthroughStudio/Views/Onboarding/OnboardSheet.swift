import SwiftUI
import AppKit

/// The pre-run sheet (ON-1.1, ON-1.10): where a run is configured in one place — the
/// repository, the output folder, the commit, an optional briefing, and the opt-in to
/// running the target's build and tests.
///
/// The fleet that consumes these settings is M11; until then the sheet validates its
/// input and hands back a configuration, and "Use a Research Packet" is the path that
/// works today — a coding agent produces the packet, the app builds everything from it.
struct OnboardSheet: View {
    @ObservedObject var vm: OnboardingViewModel
    @Environment(\.dismiss) private var dismiss

    enum Source: String, CaseIterable, Identifiable {
        case repository = "A repository"
        case packet = "A Research Packet"
        var id: String { rawValue }
    }

    @State private var source: Source = .packet
    @State private var repoText = ""
    @State private var packetPath = ""
    @State private var repoPath = ""
    @State private var outputPath = ""
    @State private var revision = ""
    @State private var briefingPath = ""
    @State private var runBuildAndTests = false
    @State private var scope = "complete"
    @State private var problem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch source {
            case .repository: repositoryFields
            case .packet: packetFields
            }

            Divider()
            commonFields

            if !problem.isEmpty {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Brand.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(source == .packet ? "Build the Package" : "Start the Run") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
            }
        }
        .padding(26)
        .frame(width: 640)
        .background(Brand.cream)
        .environment(\.colorScheme, .light)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Onboard to a Codebase")
                .font(.custom("Georgia", size: 26))
                .foregroundStyle(Brand.charcoal)
            Text("Research and content are separated by the Research Packet contract: any "
                 + "coding agent can produce a packet, and this app builds every deliverable "
                 + "from it. Point it at a packet you already have, or at a repository to "
                 + "research here.")
                .font(.caption)
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var repositoryFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Repository", placeholder: "https://github.com/acme/orders  or  /Users/me/src/orders",
                  text: $repoText) { chooseFolder(into: $repoText, message: "Choose a local clone.") }
            field("Commit (blank = the default branch's head)", placeholder: "ab12cd9 or a tag",
                  text: $revision, chooser: nil)
            Toggle(isOn: $runBuildAndTests) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run this repository's build and tests")
                    Text("Off by default. Turning it on executes the repository's own scripts on "
                         + "your Mac, with whatever they do. What ran, and what was skipped, is "
                         + "recorded in the package either way.")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker("Scope", selection: $scope) {
                Text("Complete").tag("complete")
                Text("Preview (a fast first look)").tag("preview")
            }
            .pickerStyle(.radioGroup)
        }
    }

    private var packetFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Research Packet", placeholder: "…/orders.packet", text: $packetPath) {
                chooseFolder(into: $packetPath, message: "Choose a .packet folder.")
            }
            field("Checkout to validate it against", placeholder: "/Users/me/src/orders",
                  text: $repoPath) {
                chooseFolder(into: $repoPath, message: "Choose the repository at the packet's commit.")
            }
            Text("The packet is validated against the checkout before anything is built: every "
                 + "anchor must resolve at the pinned commit. A packet with a dangling anchor is "
                 + "rejected with the reason, not imported.")
                .font(.caption)
                .foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var commonFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Output folder", placeholder: "Where the .onboarding package is written",
                  text: $outputPath) {
                chooseFolder(into: $outputPath, message: "Choose where to write the package.")
            }
            field("Briefing (optional)", placeholder: "A PDF, markdown or text file the research should trust",
                  text: $briefingPath) {
                chooseFile(into: $briefingPath)
            }
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>,
                       chooser: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Brand.muted)
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                if let chooser {
                    Button("Choose…", action: chooser)
                }
            }
        }
    }

    // MARK: Actions

    /// Validates, then hands off. Nothing here writes to disk: a sheet that half-starts
    /// a run and then reports a bad path has already made a mess.
    private func start() {
        problem = ""
        let output = expand(outputPath)

        switch source {
        case .packet:
            let packet = expand(packetPath)
            let repo = expand(repoPath)
            if let complaint = OnboardSheetValidation.problem(packet: packet, repo: repo, output: output) {
                return complain(complaint)
            }
            dismiss()
            let briefing = briefingPath.isEmpty ? nil : URL(fileURLWithPath: expand(briefingPath))
            Task { @MainActor in
                await vm.buildPackage(fromPacketAt: URL(fileURLWithPath: packet),
                                      repo: URL(fileURLWithPath: repo),
                                      outputDir: URL(fileURLWithPath: output),
                                      briefing: briefing)
            }
        case .repository:
            let repo = expand(repoText)
            if let complaint = OnboardSheetValidation.repositoryProblem(repo: repo, output: output) {
                return complain(complaint)
            }
            complain("Researching a repository in the app arrives with the research fleet (M11). "
                     + "Until then, run the onboarding-research skill in the repository and open its "
                     + "packet with the other tab — the app builds every deliverable from it.")
        }
    }

    private func complain(_ message: String) {
        problem = message
    }

    private func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("~") ? NSString(string: trimmed).expandingTildeInPath : trimmed
    }

    private func chooseFolder(into binding: Binding<String>, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }

    private func chooseFile(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a briefing document."
        if panel.runModal() == .OK, let url = panel.url { binding.wrappedValue = url.path }
    }
}


/// The sheet's validation, outside the view so a probe can drive it (ON-1.1: "validation
/// rejects non-git targets with a readable message" is only true if something checks).
///
/// Every message names the thing that is wrong and what would be right. "Invalid input"
/// tells a reader nothing they did not already know.
enum OnboardSheetValidation {

    /// nil when the form is ready to submit.
    static func problem(packet: String, repo: String, output: String) -> String? {
        if let missing = outputProblem(output) { return missing }
        guard !packet.isEmpty else { return "Choose the Research Packet folder." }
        guard FileManager.default.fileExists(atPath: packet + "/packet.json") else {
            return "\(packet) has no packet.json — that is not a Research Packet."
        }
        guard !repo.isEmpty else {
            return "Choose the repository checkout the packet is pinned to; every anchor is "
                + "verified against it before anything is built."
        }
        guard FileManager.default.fileExists(atPath: repo + "/.git") else {
            return "\(repo) is not a git clone (no .git directory), so the packet's anchors "
                + "cannot be verified against it."
        }
        return nil
    }

    static func repositoryProblem(repo: String, output: String) -> String? {
        if let missing = outputProblem(output) { return missing }
        guard !repo.isEmpty else { return "Enter a repository URL or choose a local clone." }
        let isRemote = repo.hasPrefix("http://") || repo.hasPrefix("https://") || repo.hasPrefix("git@")
        guard isRemote || FileManager.default.fileExists(atPath: repo + "/.git") else {
            return "\(repo) is not a git repository. Give a clone URL, or a folder containing "
                + "a .git directory."
        }
        return nil
    }

    private static func outputProblem(_ output: String) -> String? {
        output.isEmpty ? "Choose an output folder." : nil
    }
}
