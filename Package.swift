// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HostShield",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "HostShieldCore"),
        .executableTarget(name: "HostShield", dependencies: ["HostShieldCore"]),
        .testTarget(name: "HostShieldCoreTests", dependencies: ["HostShieldCore"]),
    ],
    swiftLanguageModes: [.v5]
)
