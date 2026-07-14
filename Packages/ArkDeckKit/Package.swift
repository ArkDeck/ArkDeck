// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ArkDeckKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArkDeckCore", targets: ["ArkDeckCore"]),
        .library(name: "ArkDeckProcess", targets: ["ArkDeckProcess"]),
        .library(name: "ArkDeckRuntime", targets: ["ArkDeckRuntime"]),
        .library(name: "ArkDeckOpenHarmony", targets: ["ArkDeckOpenHarmony"]),
        .library(name: "ArkDeckWorkflows", targets: ["ArkDeckWorkflows"]),
        .library(name: "ArkDeckStorage", targets: ["ArkDeckStorage"]),
    ],
    targets: [
        .target(name: "ArkDeckCore"),
        .target(name: "ArkDeckProcess", dependencies: ["ArkDeckCore"]),
        .target(name: "ArkDeckRuntime", dependencies: ["ArkDeckCore"]),
        .target(name: "ArkDeckOpenHarmony", dependencies: ["ArkDeckCore", "ArkDeckProcess"]),
        .target(name: "ArkDeckWorkflows", dependencies: ["ArkDeckCore"]),
        .target(name: "ArkDeckStorage", dependencies: ["ArkDeckCore"]),
        .testTarget(name: "ArkDeckCoreTests", dependencies: ["ArkDeckCore"]),
        .testTarget(
            name: "ArkDeckContractTests",
            dependencies: [
                "ArkDeckCore",
                "ArkDeckProcess",
                "ArkDeckRuntime",
                "ArkDeckOpenHarmony",
                "ArkDeckWorkflows",
                "ArkDeckStorage",
            ]
        ),
    ]
)
