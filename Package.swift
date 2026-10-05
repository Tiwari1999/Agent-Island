// swift-tools-version: 5.10
// 5.10, not 6.0: a 5.x manifest builds in Swift 5 mode on every 5.10+/6.x toolchain, while
// `.swiftLanguageMode` does not exist in older 6.x Command Line Tools and broke installs.
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v14)],
    // A binary xcframework, so Command Line Tools link it with no Xcode build of Sparkle's sources.
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")],
    targets: [
        .executableTarget(
            name: "AgentIsland",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AgentIsland",
            // SPM adds no rpath for the framework: the bundle finds it in Contents/Frameworks,
            // the bare .build binary (the suite, `--check-proc`) beside itself.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@loader_path"])]
        )
    ]
)
