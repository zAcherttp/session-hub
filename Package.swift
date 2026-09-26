// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SessionHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SessionHub", path: "Sources/SessionHub")
    ]
)
