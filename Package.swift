// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlbumscapeLock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AlbumscapeLock",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
