// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TaiChi",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/httpswift/swifter.git", .upToNextMajor(from: "1.5.0"))
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "TaiChi",
            dependencies: [
                .product(name: "Swifter", package: "swifter")
            ],
            resources: [
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "TaiChiTests",
            dependencies: ["TaiChi"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
