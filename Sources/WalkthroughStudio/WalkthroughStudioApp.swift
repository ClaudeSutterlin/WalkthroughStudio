import SwiftUI
import AppKit

@main
struct WalkthroughStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Walkthrough Studio") {
            ContentView()
                .frame(minWidth: 1100, minHeight: 720)
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched via `swift run` (no bundle): become a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Hidden headless smoke test of the non-AI pipeline:
        //   WalkthroughStudio --selftest <video> <outputDir>
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest"),
           CommandLine.arguments.count > flagIndex + 2 {
            setvbuf(stdout, nil, _IONBF, 0) // unbuffered so progress prints live
            let videoURL = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
            let outDir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
            Task { @MainActor in
                do {
                    try await SelfTest.run(videoURL: videoURL, outDir: outDir)
                    print("SELFTEST PASS")
                    exit(0)
                } catch {
                    print("SELFTEST FAIL: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }

        // Hidden headless selftest of the "Onboard to a Codebase" feature
        // (docs/onboarding/ARCHITECTURE.md section 9):
        //   WalkthroughStudio --selftest-onboarding <fixtureRepo> <outputDir> [--probe <name>]
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--selftest-onboarding"),
           CommandLine.arguments.count > flagIndex + 2 {
            setvbuf(stdout, nil, _IONBF, 0) // unbuffered so progress prints live
            let fixtureRepo = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
            let outDir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
            let onlyProbe: String? = {
                guard let probeIndex = CommandLine.arguments.firstIndex(of: "--probe"),
                      CommandLine.arguments.count > probeIndex + 1 else { return nil }
                return CommandLine.arguments[probeIndex + 1]
            }()
            Task { @MainActor in
                do {
                    try await SelfTest.runOnboarding(fixtureRepo: fixtureRepo, outDir: outDir, only: onlyProbe)
                    print("SELFTEST PASS")
                    exit(0)
                } catch {
                    print("SELFTEST FAIL: \(error.localizedDescription)")
                    exit(1)
                }
            }
        }

        // Hidden headless Research Packet validator, the Swift twin of
        // .claude/skills/onboarding-research/scripts/validate_packet.py
        // (docs/onboarding/PACKET.md section 7):
        //   WalkthroughStudio --validate-packet <packetDir> <repoDir>
        // Prints the same report and exits 0 only with zero errors.
        if let flagIndex = CommandLine.arguments.firstIndex(of: "--validate-packet"),
           CommandLine.arguments.count > flagIndex + 2 {
            setvbuf(stdout, nil, _IONBF, 0)
            let packetDir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 1])
            let repoDir = URL(fileURLWithPath: CommandLine.arguments[flagIndex + 2])
            Task { @MainActor in
                do {
                    let packet = try PacketReader.load(packetDir)
                    let validator = PacketValidator(packet: packet, repo: repoDir, git: GitRunner())
                    let report = try await validator.validate()
                    for line in report.consoleLines { print(line) }
                    exit(report.ok ? 0 : 1)
                } catch {
                    // PacketReader throws "<file>: <reason>"; print it at that
                    // file, like `ERROR   facts.jsonl: file missing` in
                    // validate_packet.py, not at the packet directory — the two
                    // reports have to be greppable side by side.
                    let text = (error as? StudioError)?.message ?? error.localizedDescription
                    var location = packetDir.lastPathComponent
                    var reason = text
                    if let split = PacketReader.splitFileReason(text) {
                        location = split.file
                        reason = split.reason
                    }
                    print("ERROR   \(location): \(reason)")
                    print("stats   {}")
                    print("PACKET INVALID: 1 errors, 0 warnings")
                    exit(1)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // In any selftest mode (--selftest, --selftest-onboarding, ...) the
        // branded renderer's offscreen windows come and go; don't let their
        // closing terminate the process mid-run.
        !CommandLine.arguments.contains { $0.hasPrefix("--selftest") }
    }
}
