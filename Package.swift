// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WalkthroughStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WalkthroughStudio",
            path: "Sources/WalkthroughStudio",
            resources: [
                .process("Resources"),
                // Onboarding assets keep their directory structure (hub/vendor/mermaid.min.js,
                // fixtures/<name>.packet/..., prompts/*.md), so they use .copy and live outside
                // Resources/ to avoid overlapping rules (docs/onboarding/ARCHITECTURE.md D14, M1 check).
                .copy("OnboardingResources"),
            ],
            linkerSettings: [
                // Embed Info.plist so `swift run` (non-bundled) still carries the
                // speech-recognition usage description. The .app bundle built by
                // build-app.sh uses Support/Info.plist instead.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ])
            ]
        )
    ]
)
