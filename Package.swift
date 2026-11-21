// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TinyWin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TinyWinCore", targets: ["TinyWinCore"]),
        .executable(name: "tinywin", targets: ["tinywin"]),
        .executable(name: "TinyWinApp", targets: ["TinyWinApp"])
    ],
    targets: [
        .target(
            name: "TinyWinCore",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .executableTarget(
            name: "tinywin",
            dependencies: ["TinyWinCore"]
        ),
        .executableTarget(
            name: "TinyWinApp",
            dependencies: ["TinyWinCore"]
        ),
        .testTarget(
            name: "TinyWinCoreTests",
            dependencies: ["TinyWinCore"]
        )
    ]
)
