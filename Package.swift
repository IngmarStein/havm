// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "havm",
    platforms: [
        .macOS(.v27)  // Golden Gate minimum
    ],
    products: [
        .executable(name: "havm", targets: ["Havm"]),
        .library(name: "HavmCore", targets: ["HavmCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0"),
    ],
    targets: [
        .executableTarget(
            name: "Havm",
            dependencies: [
                "HavmCore",
                "HavmRuntime",
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
            ],
            linkerSettings: [
                .linkedFramework("AccessoryAccess"),
            ]
        ),
        .target(
            name: "HavmRuntime",
            dependencies: [
                "HavmCore",
                .product(name: "Logging", package: "swift-log"),
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
