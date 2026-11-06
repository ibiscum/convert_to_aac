// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "convert_to_aac",
    platforms: [
        .macOS("27.0"),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.13.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .systemLibrary(
            name: "CFLAC",
            pkgConfig: "flac"
        ),
        .executableTarget(
            name: "convert_to_aac",
            dependencies: [
                "CFLAC",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "convert_to_aacTests",
            dependencies: [
                "convert_to_aac",
                .product(name: "Testing", package: "swift-testing"),
            ],
            swiftSettings: [
                .unsafeFlags(["-suppress-warnings"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
