// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "blescan",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "blescan",
            path: "Sources/blescan"
        )
    ]
)
