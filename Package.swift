// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SixFingers",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SixFingers",
            path: "Sources/SixFingers",
            resources: [
                .copy("../../Resources"),
            ]
        ),
    ]
)
