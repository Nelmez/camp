// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Camp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Camp", targets: ["Camp"]),
    ],
    targets: [
        .executableTarget(
            name: "Camp",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
