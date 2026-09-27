// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OneMix",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "OneMixCore"),
        .executableTarget(name: "OneMix", dependencies: ["OneMixCore"]),
        .testTarget(name: "OneMixCoreTests", dependencies: ["OneMixCore"]),
    ],
    swiftLanguageModes: [.v5]
)
