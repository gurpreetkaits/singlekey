// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SingleKey",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SingleKey", path: "Sources/SingleKey")
    ]
)
