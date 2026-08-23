// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClientTimeTracker",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClientTimeTracker",
            path: "Sources/ClientTimeTracker"
        )
    ]
)
