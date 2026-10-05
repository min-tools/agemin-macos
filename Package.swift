// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Agemin",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AgeminApp",
            path: "Sources/AgeminApp",
            resources: [.process("Resources")],
            swiftSettings: [.define("AGEMIN_SWIFTPM")]
        )
    ],
    // The app is written for the Swift 5 language mode, as in the Xcode project and build script.
    swiftLanguageModes: [.v5]
)
