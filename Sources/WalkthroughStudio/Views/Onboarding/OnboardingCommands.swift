import SwiftUI

/// The File menu entry that opens the onboarding window (ON-1.1, D3).
///
/// A separate `Window` scene rather than a tab in the studio: onboarding to a codebase
/// and editing a screen recording are different sittings, and a reader wants the
/// package open beside their editor, not inside a video tool.
struct OnboardingCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Onboard to a Codebase…") {
                openWindow(id: OnboardingWindow.id)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}

enum OnboardingWindow {
    static let id = "onboarding"
    static let title = "Onboarding"
}
