// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Vigil",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "vigil", targets: ["vigil"]),
    ],
    targets: [
        // Pure logic (holds, safety policy, parsing, hook config). Foundation only, fully unit-tested.
        .target(name: "VigilCore"),
        // One binary: menu-bar app, CLI and watchdog, picked by argv.
        .executableTarget(
            name: "vigil",
            dependencies: ["VigilCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(name: "VigilCoreTests", dependencies: ["VigilCore"]),
    ]
)
