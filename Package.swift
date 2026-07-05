// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WalkthroughStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WalkthroughStudio",
            path: "Sources/WalkthroughStudio",
            resources: [.process("Resources")],
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
