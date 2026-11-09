// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacPaste",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacPaste",
            path: "Sources/MacPaste",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
