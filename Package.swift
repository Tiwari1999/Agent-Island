// swift-tools-version: 6.0
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
            swiftSettings: [.swiftLanguageMode(.v5)],
            // SPM adds no rpath for the framework: the bundle finds it in Contents/Frameworks,
            // the bare .build binary (the suite, `--check-proc`) beside itself.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                           "-Xlinker", "-rpath", "-Xlinker", "@loader_path"])]
        )
    ]
)
