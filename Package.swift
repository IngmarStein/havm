// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "havm",
    platforms: [
        .macOS(.v27)  // Golden Gate minimum
    ],
    products: [
        .executable(name: "havm", targets: ["Havm"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "Havm",
            dependencies: [
                "HavmCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "HavmCore",
            dependencies: [
                "CXZ",
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
            ],
            linkerSettings: [
                .linkedFramework("AccessoryAccess"),
            ]
        ),
        .target(
            name: "CXZ",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("lzma"),
            ]
        ),
        .testTarget(
            name: "HavmCoreTests",
            dependencies: ["HavmCore"]
        ),
    ]
)
