// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Camp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Camp", targets: ["Camp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.3"),
    ],
    targets: [
        .executableTarget(
            name: "Camp",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
