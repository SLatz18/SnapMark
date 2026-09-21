// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapMark",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SnapMark",
            path: "Sources/SnapMark"
        ),
        .testTarget(
            name: "SnapMarkTests",
            dependencies: ["SnapMark"],
            path: "Tests/SnapMarkTests"
        ),
    ]
)
