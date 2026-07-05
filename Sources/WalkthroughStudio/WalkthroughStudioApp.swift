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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // In selftest mode the branded renderer's offscreen windows come and go;
        // don't let their closing terminate the process mid-run.
        !CommandLine.arguments.contains("--selftest")
    }
}
