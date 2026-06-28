// swift-tools-version:5.9
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
