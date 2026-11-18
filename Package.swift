// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MyMac", path: "Sources/MyMac")
    ]
)
