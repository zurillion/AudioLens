// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HelloWorldSPM",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HelloWorldSPM",
            path: "Sources/HelloWorldSPM"
        )
    ]
)
