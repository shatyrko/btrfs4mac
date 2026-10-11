// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "btrfs4mac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "btrfs4mac", path: "Sources/btrfs4mac")
    ]
)
