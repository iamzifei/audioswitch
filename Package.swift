// swift-tools-version: 6.0
import PackageDescription

// AudioSwitch — a menu bar utility for switching the default macOS audio
// input / output device.
//
// The package is split into two targets so that the CoreAudio logic can be
// unit tested without launching the SwiftUI application:
//   * AudioSwitchCore — device enumeration + default-device switching
//   * AudioSwitch     — the SwiftUI MenuBarExtra shell
let package = Package(
    name: "AudioSwitch",
    // Base language for the interface; zh-Hans and zh-Hant ship alongside it.
    defaultLocalization: "en",
    // MenuBarExtra requires macOS 13; we target 14 to keep the SwiftUI code simple.
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle: the macOS auto-update framework. Ships as a binary
        // XCFramework via SwiftPM; build.sh copies Sparkle.framework into the
        // .app bundle and signs its nested code inside-out.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "AudioSwitchCore",
            // Language mode 5: CoreAudio's C callbacks are not annotated for
            // Swift 6 strict concurrency, so full checking produces noise we
            // cannot fix from our side.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioSwitch",
            dependencies: [
                "AudioSwitchCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // Localizations live in Resources/<lang>.lproj and are read at
            // runtime so the language can be switched without a restart.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // So the runtime finds Sparkle.framework in Contents/Frameworks
            // after build.sh copies it there. -Xlinker passes -rpath through
            // the Swift driver to the actual linker.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ])
            ]
        ),
        .testTarget(
            name: "AudioSwitchCoreTests",
            dependencies: ["AudioSwitchCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
